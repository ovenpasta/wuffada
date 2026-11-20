// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

// This file lowers Wuffs coroutines (functions marked "?").
//
// A coroutine can return a suspension status ("$short read") from a
// suspension point in the middle of its body, and continues from that point
// when it is called again. The C back-end does that with a switch statement
// whose case labels sit inside the loops and ifs of the body. Ada has no
// such thing: a goto cannot enter a compound statement. So, per
// docs/DESIGN.md "Coroutines":
//
//   - lowering (lower.go) produces ordinary structured IR in which each
//     suspension point is an sResume marker;
//   - the flatten pass below rewrites every compound statement that
//     contains a marker into labels and gotos at the top level of the
//     subprogram, and leaves everything else structured;
//   - the function starts with a case statement that jumps to the label of
//     the saved suspension point.
//
// What state is saved where follows the C back-end exactly (func.go,
// statement.go, var.go, liveness.go in the Wuffs repository's
// internal/cgen), since it is observable:
//
//   - Self.G_P_Func is the suspension point to resume at, or 0. It is set at
//     the Suspend label (to 0 unless the status is a suspension) and reset
//     at the Ok label. An error return goes straight to the Exit label and
//     leaves it alone.
//   - Only the locals that findResumables (a port of the C back-end's
//     liveness analysis) finds live across a suspension are saved, in
//     Self.G_S_Func_Var, and only at the Suspend label. Every other local
//     starts at zero again when the coroutine is resumed. Slice-typed
//     locals are never saved (C: "HasPointers").
//   - I/O cursors are rebuilt from the buffers' metas on every call and
//     stored back at the Exit label.

// One consequence of following C exactly is worth spelling out. If a caller
// swallows an error from a private coroutine (with "=?") and calls it again,
// the callee's G_P_Func still holds the suspension point of its last
// suspension, because an error exit does not reset it. The callee then
// resumes in the middle of its body, with whatever its saved locals and
// scratch word hold. In C that is undefined in general (for example, the
// loop that assembles a read_u32be? from the scratch word can shift by more
// than the word's width). Here it is defined but meaningless in the release
// profile, and in the checked profile it can fail a precondition of the base
// library (Read_Step_BE's, on the scratch word). The two profiles therefore
// differ only where C has no defined behaviour to match. No package of
// Wuffs' standard library does this: a caller that sees an error returns it.
// The generator does not try to detect the pattern.

// The labels of a coroutine's epilogue.
const (
	labelOk      = prefixGen + "Ok"
	labelSuspend = prefixGen + "Suspend"
	labelExit    = prefixGen + "Exit"
)

// activeCoroutineField is the record component that says which public
// coroutine of an object is suspended (C: private_impl.active_coroutine).
const activeCoroutineField = prefixGen + "Active_Coroutine"

func resumeLabel(n int) string { return fmt.Sprintf("%sResume_%d", prefixGen, n) }

// suspPoint returns the marker for a new suspension point: "the suspension
// point is now n", and where to resume for n (C:
// WUFFS_BASE__COROUTINE_SUSPENSION_POINT).
func (l *lowerer) suspPoint() stmt {
	l.nSusp++
	if l.susp == nil {
		l.susp = l.newLocal(prefixGen+"Susp", typU32, nil)
	}
	return sResume{n: l.nSusp, susp: l.susp}
}

// stateName returns the name of a record component that holds a piece of
// this coroutine's state: "G_<kind>_<n>_<Func>" or, for a saved local,
// "G_<kind>_<n>_<Func>_<Var>".
//
// n is the function's number among the package's functions. It is what
// makes the name unambiguous: the function's and the variable's names can
// both contain underscores (func "p_q" with a local "r", and func "p" with a
// local "q_r"), but n determines the function, and so where its name ends.
// The names are there for the reader.
func (l *lowerer) stateName(kind string, local string) string {
	name := fmt.Sprintf("%s%s_%d_%s", prefixGen, kind, l.fi.number, l.f.name)
	if local != "" {
		name += "_" + local
	}
	return name
}

// pField returns Self.G_P_Func, the coroutine's saved suspension point (C:
// private_impl.p_func), declaring the record component on first use.
func (l *lowerer) pField() expr {
	if l.pfield == nil {
		name := l.stateName("P", "")
		l.fi.recv.extra = append(l.fi.recv.extra, fieldInfo{name: name, typ: typU32})
		l.pfield = eSel{eVar{l.f.self}, name}
	}
	return l.pfield
}

// scratchField returns the coroutine's scratch word, which survives
// suspension (C: private_data.s_func.scratch).
func (l *lowerer) scratchField() expr {
	if l.scratch == nil {
		name := l.stateName("Scratch", "")
		l.fi.recv.extra = append(l.fi.recv.extra, fieldInfo{name: name, typ: typU64})
		l.scratch = eSel{eVar{l.f.self}, name}
	}
	l.f.self.writes++
	return l.scratch
}

// suspendWith returns the statements for "status = s; goto suspend".
func (l *lowerer) suspendWith(status string) []stmt {
	return []stmt{sAssign{eVar{l.status}, raw(basePkg + "." + status)}, sGoto{labelSuspend}}
}

// coroutineRet lowers a return or a yield in a coroutine, as the C
// back-end's writeStatementRet does.
func (l *lowerer) coroutineRet(n *a.Ret) ([]stmt, error) {
	value := n.Value()
	if value == nil {
		return nil, fmt.Errorf("%s without a value in a coroutine", n.Keyword().Str(l.g.tm))
	}
	v, err := l.expr(value)
	if err != nil {
		return nil, err
	}
	if v.typ == nil || v.typ.kind != kStatus {
		return nil, fmt.Errorf("%q is not a status", value.Str(l.g.tm))
	}
	status := eVar{l.status}
	kind := l.statusLiteralKind(value)
	ret := l.flush(sAssign{status, v.e})

	switch n.Keyword() {
	case t.IDYield:
		// C: WUFFS_BASE__COROUTINE_SUSPENSION_POINT_MAYBE_SUSPEND.
		if kind != '$' {
			ret = append(ret, sIf{branches: []ifBranch{
				{call("Wuffs.Is_Ok", status), []stmt{sGoto{labelOk}}},
				{eUn{"not", call("Wuffs.Is_Suspension", status)}, []stmt{sGoto{labelExit}}},
			}})
		}
		r := l.suspPoint().(sResume)
		r.labelOnly = true
		return append(ret, sAssign{eVar{l.susp}, raw(fmt.Sprint(r.n))}, sGoto{labelSuspend}, r), nil

	case t.IDReturn:
		switch {
		case n.RetsError() || kind == '#':
			return append(ret, sGoto{labelExit}), nil
		case kind == 'o' || kind == '@':
			return append(ret, sGoto{labelOk}), nil
		}
		return append(ret,
			sIf{branches: []ifBranch{
				{call("Wuffs.Is_Error", status), []stmt{sGoto{labelExit}}},
				{call("Wuffs.Is_Suspension", status), []stmt{
					sAssign{status, raw(basePkg + ".Error_Cannot_Return_A_Suspension")},
					sGoto{labelExit},
				}},
			}},
			sGoto{labelOk}), nil
	}
	return nil, fmt.Errorf("unrecognized return keyword %q", n.Keyword().Str(l.g.tm))
}

// assembleCoroutine puts a coroutine's body together: head (the public
// function's checks and the I/O cursors), the restoring of saved locals, the
// dispatch on the saved suspension point, the flattened body and the
// epilogue.
func (l *lowerer) assembleCoroutine(head []stmt, body []stmt) []stmt {
	self := eVar{l.f.self}
	status := eVar{l.status}
	l.f.self.writes++
	out := head

	pField := expr(nil)
	saved := [][2]expr(nil) // Pairs of a local and its record component.
	if l.nSusp > 0 {
		pField = l.pField()
		l.g.useType[32] = true

		// The locals to save, in declaration order.
		for _, o := range l.fi.ast.Body() {
			if o.Kind() != a.KVar {
				break
			}
			id := o.AsVar().Name()
			v := l.locals[id]
			if v == nil && l.ioLocals[id] {
				continue
			}
			// C does not save a variable whose type has pointers (a slice
			// or a table) either.
			if !l.resumables[id] || v.typ.kind == kROSliceU8 || v.typ.kind == kSliceU8 || v.typ.kind == kTable ||
				v.typ.kind == kRowPtr {
				continue
			}
			name := l.stateName("S", mangle(id.Str(l.g.tm)))
			l.fi.recv.extra = append(l.fi.recv.extra, fieldInfo{name: name, typ: v.typ})
			saved = append(saved, [2]expr{eVar{v}, eSel{self, name}})
		}

		susp := eVar{l.susp}
		out = append(out, sAssign{susp, pField})
		if len(saved) > 0 {
			restore := []stmt(nil)
			for _, o := range saved {
				restore = append(restore, sAssign{o[0], o[1]})
			}
			out = append(out, sIf{branches: []ifBranch{{bin("/=", susp, raw("0")), restore}}})
		}
		dispatch := sCase{sel: susp, arms: []caseArm{{"0", nil}}}
		for i := 1; i <= l.nSusp; i++ {
			dispatch.arms = append(dispatch.arms, caseArm{fmt.Sprint(i), []stmt{sGoto{resumeLabel(i)}}})
		}
		// C's switch has no default: an unknown value skips the body.
		dispatch.others = []stmt{sGoto{labelSuspend}}
		out = append(out, dispatch)
	}

	out = append(out, flatten(body)...)

	// C: "ok:". Falling off the end of the body arrives here too.
	out = append(out, sLabel{labelOk})
	if l.nSusp > 0 {
		out = append(out, sAssign{pField, raw("0")}, sGoto{labelExit})

		// C: "suspend:".
		isSusp := call("Wuffs.Is_Suspension", status)
		out = append(out, sLabel{labelSuspend},
			sAssign{pField, eIf{isSusp, eVar{l.susp}, raw("0")}})
		if l.f.public {
			out = append(out, sAssign{eSel{self, activeCoroutineField},
				eIf{isSusp, raw(fmt.Sprint(l.fi.coroID)), raw("0")}})
		}
		for _, o := range saved {
			out = append(out, sAssign{o[1], o[0]})
		}
	}

	// C: "exit:".
	out = append(out, sLabel{labelExit})
	out = append(out, l.saveCursors()...)
	if l.f.public {
		out = append(out, sIf{branches: []ifBranch{{call("Wuffs.Is_Error", status), []stmt{
			sAssign{eSel{self, "Magic"}, raw(rtMagicDisabled)}}}}})
	}
	out = append(out, sReturn{status})
	return dropUnusedLabels(out)
}

// checkTemps verifies that, in the IR ss of one Wuffs statement of a
// coroutine, no generator temporary is read after a resume label unless it
// was assigned after that label. A temporary is an ordinary Ada local: it is
// not saved across a suspension, so a value computed before the label would
// be garbage (or stale) when the coroutine is resumed there. Lowering is
// written so that this cannot happen (whatever a suspending call needs is
// computed after its resume label); this check turns any future mistake into
// a generation error instead of wrong code.
//
// The IR says which actual parameters of a procedure call are "out" ones
// (eOut): those are assignments. A temporary anywhere else in a call is a
// read.
func (l *lowerer) checkTemps(ss []stmt) error {
	defined := map[*variable]bool{}
	return l.checkTempsIn(ss, defined)
}

func (l *lowerer) checkTempsIn(ss []stmt, defined map[*variable]bool) error {
	bad := (*variable)(nil)
	outs := []*variable(nil)
	var read func(e expr)
	read = func(e expr) {
		switch e := e.(type) {
		case eVar:
			if l.temps[e.v] && !defined[e.v] && bad == nil {
				bad = e.v
			}
		case eSel:
			read(e.x)
		case eAttr:
			read(e.x)
		case eCall:
			read(e.fn)
			for _, o := range e.args {
				read(o)
			}
		case eSlice:
			read(e.x)
			read(e.lo)
			read(e.hi)
		case eQual:
			read(e.x)
		case eNamed:
			read(e.x)
		case eRel:
			read(e.l)
			read(e.r)
		case eOut:
			if v, ok := e.x.(eVar); ok && l.temps[v.v] {
				outs = append(outs, v.v)
			} else {
				read(e.x)
			}
		case eUn:
			read(e.x)
		case eBin:
			for _, o := range e.args {
				read(o)
			}
		case eAgg:
			for _, o := range e.vals {
				read(o)
			}
		case eIf:
			read(e.cond)
			read(e.yes)
			read(e.no)
		}
	}
	copyOf := func(m map[*variable]bool) map[*variable]bool {
		c := map[*variable]bool{}
		for k, v := range m {
			c[k] = v
		}
		return c
	}
	intersect := func(dst map[*variable]bool, other map[*variable]bool) {
		for k := range dst {
			if !other[k] {
				delete(dst, k)
			}
		}
	}

	for _, s := range ss {
		switch s := s.(type) {
		case sResume:
			for k := range defined {
				delete(defined, k)
			}
		case sAssign:
			read(s.rhs)
			if v, ok := s.lhs.(eVar); ok && l.temps[v.v] {
				defined[v.v] = true
			} else {
				read(s.lhs)
			}
		case sCall:
			// The call reads its "in" actuals and then assigns its "out"
			// ones, which the IR marks with eOut.
			outs = nil
			read(s.call)
			for _, v := range outs {
				defined[v] = true
			}
		case sIf:
			result := (map[*variable]bool)(nil)
			for _, br := range s.branches {
				read(br.cond)
				d := copyOf(defined)
				if err := l.checkTempsIn(br.body, d); err != nil {
					return err
				}
				if result == nil {
					result = d
				} else {
					intersect(result, d)
				}
			}
			d := copyOf(defined)
			if err := l.checkTempsIn(s.els, d); err != nil {
				return err
			}
			intersect(result, d)
			for k := range defined {
				delete(defined, k)
			}
			for k := range result {
				defined[k] = true
			}
		case sLoop:
			d := copyOf(defined)
			if anyResume(s.body) {
				// A later iteration may have come by way of a resume.
				d = map[*variable]bool{}
			}
			if s.cond != nil {
				saved := defined
				defined = d
				read(s.cond)
				defined = saved
			}
			if err := l.checkTempsIn(s.body, d); err != nil {
				return err
			}
			if s.cond != nil || anyResume(s.body) {
				intersect(defined, d)
			} else {
				for k := range d {
					defined[k] = true
				}
			}
		case sExitWhen:
			read(s.cond)
		case sReturn:
			if s.value != nil {
				read(s.value)
			}
		case sPragma:
			for _, o := range s.args {
				read(o)
			}
		case sCase:
			read(s.sel)
		}
		if bad != nil {
			return fmt.Errorf("internal error: the temporary %s would be read after a suspension point "+
				"that it was computed before", bad.name)
		}
	}
	return nil
}

// ---- Flattening.

// hasResume reports whether s contains a suspension point.
func hasResume(s stmt) bool {
	switch s := s.(type) {
	case sResume:
		return true
	case sIf:
		for _, br := range s.branches {
			if anyResume(br.body) {
				return true
			}
		}
		return anyResume(s.els)
	case sLoop:
		return anyResume(s.body)
	}
	return false
}

func anyResume(ss []stmt) bool {
	for _, s := range ss {
		if hasResume(s) {
			return true
		}
	}
	return false
}

type flattener struct {
	n int

	// breakLabels maps the name of a flattened loop to the label after it.
	breakLabels map[string]string
}

// flatten rewrites ss so that every suspension point's resume label is at
// the top level: each if and loop that contains a suspension point becomes
// labels and gotos, recursively. Statements without one are kept as they
// are, except that an exit from a loop that was flattened becomes a goto.
func flatten(ss []stmt) []stmt {
	fl := &flattener{breakLabels: map[string]string{}}
	return fl.list(ss)
}

// label makes a new label. The labels of flattened statements are
// G_Head_<n> and G_Done_<n> (a loop's start and what follows it), G_Else_<n>
// and G_Fi_<n> (an if's next branch and what follows it). Their first words
// differ from those of every other kind of name in a subprogram (Ada loop
// names are G_Loop_<n>, continue labels G_Continue_<n>, resume labels
// G_Resume_<n>), and n is unique among them.
func (fl *flattener) label(what string) string {
	fl.n++
	return fmt.Sprintf("%s%s_%d", prefixGen, what, fl.n)
}

// endsWithJump reports whether control cannot fall off the end of ss.
func endsWithJump(ss []stmt) bool {
	if len(ss) == 0 {
		return false
	}
	switch ss[len(ss)-1].(type) {
	case sGoto, sReturn, sExit:
		return true
	}
	return false
}

func (fl *flattener) list(ss []stmt) []stmt {
	out := []stmt(nil)
	for _, s := range ss {
		if !hasResume(s) {
			out = append(out, fl.rewriteExits(s))
			continue
		}
		switch s := s.(type) {
		case sResume:
			out = append(out, s)

		case sIf:
			end := fl.label("Fi")
			for _, br := range s.branches {
				next := fl.label("Else")
				out = append(out, sIf{branches: []ifBranch{{negate(br.cond), []stmt{sGoto{next}}}}})
				out = append(out, fl.list(br.body)...)
				if !endsWithJump(out) {
					out = append(out, sGoto{end})
				}
				out = append(out, sLabel{next})
			}
			out = append(out, fl.list(s.els)...)
			out = append(out, sLabel{end})

		case sLoop:
			head, brk := fl.label("Head"), fl.label("Done")
			if s.name != "" {
				fl.breakLabels[s.name] = brk
			}
			out = append(out, sLabel{head})
			if s.cond != nil {
				out = append(out, sIf{branches: []ifBranch{{negate(s.cond), []stmt{sGoto{brk}}}}})
			}
			// A flattened loop is no longer an Ada loop, so its invariants
			// are plain assertions at the same place.
			body := append([]stmt(nil), s.body...)
			for i, o := range body {
				if p, ok := o.(sPragma); ok && p.name == "Loop_Invariant" {
					p.name = "Assert"
					body[i] = p
				}
			}
			out = append(out, fl.list(body)...)
			if !endsWithJump(out) {
				out = append(out, sGoto{head})
			}
			out = append(out, sLabel{brk})

		default:
			panic(fmt.Sprintf("adagen: internal error: cannot flatten %T", s))
		}
	}
	return out
}

// negate returns the Ada condition "not e", simplified where that is
// obviously possible. A negated comparison is still an eRel, so it gets the
// same normalisation as any other when it is printed.
func negate(e expr) expr {
	switch e := e.(type) {
	case eUn:
		if e.op == "not" {
			return e.x
		}
	case eRel:
		return e.negated()
	}
	return eUn{"not", e}
}

// rewriteExits returns s with every exit from a flattened loop replaced by a
// goto to the label after that loop.
func (fl *flattener) rewriteExits(s stmt) stmt {
	switch s := s.(type) {
	case sExit:
		if label, ok := fl.breakLabels[s.name]; ok {
			return sGoto{label}
		}
	case sIf:
		ret := sIf{}
		for _, br := range s.branches {
			ret.branches = append(ret.branches, ifBranch{br.cond, fl.rewriteList(br.body)})
		}
		ret.els = fl.rewriteList(s.els)
		return ret
	case sLoop:
		return sLoop{name: s.name, cond: s.cond, body: fl.rewriteList(s.body)}
	}
	return s
}

func (fl *flattener) rewriteList(ss []stmt) []stmt {
	if ss == nil {
		return nil
	}
	out := make([]stmt, len(ss))
	for i, s := range ss {
		out[i] = fl.rewriteExits(s)
	}
	return out
}

// dropUnusedLabels removes the labels that nothing jumps to and the jumps
// that nothing reaches (GNAT warns about both), at the top level of ss. One
// removal can enable another (a flattened endless loop that nothing breaks
// out of leaves "goto head; <<done>>; goto fi"), so it repeats until
// nothing changes.
func dropUnusedLabels(ss []stmt) []stmt {
	for {
		n := len(ss)
		ss = dropUnusedLabelsOnce(ss)
		out := []stmt(nil)
		for _, s := range ss {
			if _, ok := s.(sGoto); ok && len(out) > 0 {
				if _, ok := out[len(out)-1].(sGoto); ok {
					continue
				}
			}
			out = append(out, s)
		}
		ss = out
		if len(ss) == n {
			return ss
		}
	}
}

func dropUnusedLabelsOnce(ss []stmt) []stmt {
	used := map[string]bool{}
	var visit func(ss []stmt)
	visit = func(ss []stmt) {
		for _, s := range ss {
			switch s := s.(type) {
			case sGoto:
				used[s.label] = true
			case sIf:
				for _, br := range s.branches {
					visit(br.body)
				}
				visit(s.els)
			case sLoop:
				visit(s.body)
			case sCase:
				for _, arm := range s.arms {
					visit(arm.body)
				}
				visit(s.others)
			}
		}
	}
	visit(ss)
	out := []stmt(nil)
	for _, s := range ss {
		switch s := s.(type) {
		case sLabel:
			if !used[s.name] {
				continue
			}
		case sResume:
			// Always used: by the dispatch.
		}
		out = append(out, s)
	}
	return out
}

// ---- Liveness.

// findResumables returns the local variables of the coroutine f whose
// values must survive a suspension. It is a port of the liveness analysis in
// the Wuffs repository's internal/cgen/liveness.go: which locals are saved
// is observable (the others are zero again on resume). The one difference
// is that assertions count as reads: see doAsserts.
//
// A variable is "weakly live" once a suspension point has been passed since
// it was last assigned, and becomes "strongly live" (resumable) when it is
// then read. A coroutine call other than a built-in I/O method makes every
// variable that its arguments mention strongly live at once.
func findResumables(tm *t.Map, f *a.Func) (map[t.ID]bool, error) {
	h := livenessHelper{
		tm:    tm,
		vars:  map[t.ID]int{},
		loops: map[a.Loop]*loopLivenesses{},
	}
	varList := []*a.Var(nil)
	for _, n := range f.Body() {
		if n.Kind() != a.KVar {
			break
		}
		varList = append(varList, n.AsVar())
		h.vars[n.AsVar().Name()] = len(h.vars)
	}

	h.final = make(livenesses, len(h.vars))
	r := make(livenesses, len(h.vars))
	if err := h.doBlock(r, f.Body()); err != nil {
		return nil, err
	}
	h.final.reconcile(r)

	ret := map[t.ID]bool{}
	for i, v := range varList {
		ret[v.Name()] = h.final[i] == livenessStrong
	}
	return ret, nil
}

type liveness uint32

const (
	livenessNone   = liveness(0)
	livenessWeak   = liveness(1)
	livenessStrong = liveness(2)
)

type livenesses []liveness

func (r livenesses) clear() {
	for i := range r {
		r[i] = livenessNone
	}
}

func (r livenesses) reconcile(s livenesses) (changed bool) {
	for i := range r {
		if r[i] < s[i] {
			r[i] = s[i]
			changed = true
		}
	}
	return changed
}

func (r livenesses) lowerWeakToNone(i int) {
	if r[i] == livenessWeak {
		r[i] = livenessNone
	}
}

func (r livenesses) raiseWeakToStrong(i int) {
	if r[i] == livenessWeak {
		r[i] = livenessStrong
	}
}

func (r livenesses) raiseNoneToWeak() {
	for i, x := range r {
		if x == livenessNone {
			r[i] = livenessWeak
		}
	}
}

type loopLivenesses struct {
	before  livenesses
	after   livenesses
	changed bool
}

type livenessHelper struct {
	tm    *t.Map
	vars  map[t.ID]int // Maps from local variable name to livenesses index.
	loops map[a.Loop]*loopLivenesses
	final livenesses
}

func (h *livenessHelper) doBlock(r livenesses, block []*a.Node) error {
loop:
	for _, o := range block {
		switch o.Kind() {
		case a.KAssert:
			// A deliberate difference from upstream: see doAsserts.
			if err := h.doExpr1(r, o.AsAssert().Condition(), false); err != nil {
				return err
			}
		case a.KAssign:
			if err := h.doAssign(r, o.AsAssign()); err != nil {
				return err
			}
		case a.KExpr:
			if err := h.doExpr(r, o.AsExpr()); err != nil {
				return err
			}
		case a.KIOManip:
			n := o.AsIOManip()
			if err := h.doExpr(r, n.IO()); err != nil {
				return err
			}
			if arg1 := n.Arg1(); arg1 != nil {
				if err := h.doExpr(r, arg1); err != nil {
					return err
				}
			}
			if histPos := n.HistoryPosition(); histPos != nil {
				if err := h.doExpr(r, histPos); err != nil {
					return err
				}
			}
			if err := h.doBlock(r, n.Body()); err != nil {
				return err
			}
		case a.KIf:
			if err := h.doIf(r, o.AsIf()); err != nil {
				return err
			}
		case a.KIterate:
			return fmt.Errorf("iterate loop is inside a coroutine")
		case a.KJump:
			if err := h.doJump(r, o.AsJump()); err != nil {
				return err
			}
			break loop
		case a.KRet:
			if err := h.doRet(r, o.AsRet()); err != nil {
				return err
			}
			if o.AsRet().Keyword() == t.IDReturn {
				break loop
			}
		case a.KVar:
			i, ok := h.vars[o.AsVar().Name()]
			if !ok {
				return fmt.Errorf("unrecognized variable %q", o.AsVar().Name().Str(h.tm))
			}
			r.lowerWeakToNone(i)
		case a.KWhile:
			if err := h.doWhile(r, o.AsWhile()); err != nil {
				return err
			}
		}
	}
	return nil
}

func (h *livenessHelper) doAssign(r livenesses, n *a.Assign) error {
	if n.Operator() == t.IDEqQuestion {
		if err := h.doExpr1(r, n.RHS(), false); err != nil {
			return err
		}
	} else {
		if err := h.doExpr(r, n.RHS()); err != nil {
			return err
		}
	}

	if n.LHS() == nil {
		return nil
	}
	if n.LHS().Operator() != 0 || (n.Operator() != t.IDEq && n.Operator() != t.IDEqQuestion) {
		if err := h.doExpr(r, n.LHS()); err != nil {
			return err
		}
	}
	if lhs := n.LHS(); lhs.Operator() == 0 {
		i, ok := h.vars[lhs.Ident()]
		if !ok {
			return fmt.Errorf("unrecognized variable %q", lhs.Ident().Str(h.tm))
		}
		r.lowerWeakToNone(i)
	}
	return nil
}

func (h *livenessHelper) doExpr(r livenesses, n *a.Expr) error {
	allToStrong := false
	if n.Effect().Coroutine() {
		recv := n.LHS().AsExpr().LHS().AsExpr()
		if !recv.MType().IsIOTokenType() {
			allToStrong = true
		}
	}
	if err := h.doExpr1(r, n, allToStrong); err != nil {
		return err
	}
	if n.Effect().Coroutine() {
		r.raiseNoneToWeak()
	}
	return nil
}

func (h *livenessHelper) doExpr1(r livenesses, n *a.Expr, allToStrong bool) error {
	for _, o := range n.AsNode().AsRaw().SubNodes() {
		if o != nil && o.Kind() == a.KExpr {
			if err := h.doExpr1(r, o.AsExpr(), allToStrong); err != nil {
				return err
			}
		}
	}
	for _, o := range n.Args() {
		e := (*a.Expr)(nil)
		switch o.Kind() {
		case a.KArg:
			e = o.AsArg().Value()
		case a.KExpr:
			e = o.AsExpr()
		default:
			return fmt.Errorf("unrecognized arg kind")
		}
		if err := h.doExpr1(r, e, allToStrong); err != nil {
			return err
		}
	}
	if n.Operator() == 0 {
		if i, ok := h.vars[n.Ident()]; ok {
			if allToStrong {
				r[i] = livenessStrong
			} else {
				r.raiseWeakToStrong(i)
			}
		}
	}
	return nil
}

func (h *livenessHelper) doIf(r livenesses, n *a.If) error {
	scratch := make(livenesses, len(r))
	result := make(livenesses, len(r))
	for {
		if err := h.doExpr(r, n.Condition()); err != nil {
			return err
		}
		copy(scratch, r)
		if err := h.doBlock(scratch, n.BodyIfTrue()); err != nil {
			return err
		}
		result.reconcile(scratch)

		if ei := n.ElseIf(); ei != nil {
			n = ei
			continue
		}
		copy(scratch, r)
		if err := h.doBlock(scratch, n.BodyIfFalse()); err != nil {
			return err
		}
		result.reconcile(scratch)
		break
	}
	copy(r, result)
	return nil
}

func (h *livenessHelper) doJump(r livenesses, n *a.Jump) error {
	l := h.loops[n.JumpTarget()]
	switch n.Keyword() {
	case t.IDBreak:
		l.changed = l.after.reconcile(r) || l.changed
	case t.IDContinue:
		l.changed = l.before.reconcile(r) || l.changed
	default:
		return fmt.Errorf("unrecognized ast.Jump keyword")
	}
	r.clear()
	return nil
}

func (h *livenessHelper) doRet(r livenesses, n *a.Ret) error {
	if err := h.doExpr(r, n.Value()); err != nil {
		return err
	}
	switch n.Keyword() {
	case t.IDReturn:
		h.final.reconcile(r)
		r.clear()
	case t.IDYield:
		r.raiseNoneToWeak()
	default:
		return fmt.Errorf("unrecognized ast.Ret keyword")
	}
	return nil
}

func (h *livenessHelper) doWhile(r livenesses, n *a.While) error {
	l := &loopLivenesses{
		before: make(livenesses, len(r)),
		after:  make(livenesses, len(r)),
	}
	h.loops[n] = l
	copy(l.before, r)

	for l.changed = true; l.changed; {
		l.changed = false
		copy(r, l.before)

		if err := h.doAsserts(r, n.Asserts(), t.IDPre, t.IDInv); err != nil {
			return err
		}
		if err := h.doExpr(r, n.Condition()); err != nil {
			return err
		} else if !n.IsWhileTrue() {
			l.changed = l.after.reconcile(r) || l.changed
		}
		if err := h.doBlock(r, n.Body()); err != nil {
			return err
		}
		l.changed = l.before.reconcile(r) || l.changed
	}
	copy(r, l.after)
	return h.doAsserts(r, n.Asserts(), t.IDInv, t.IDPost)
}

// doAsserts counts the conditions of the loop assertions with one of the
// given keywords as reads of the variables that they mention.
//
// This is the one deliberate difference from upstream's liveness.go, which
// ignores assertions: C does not evaluate them. This back-end lowers them
// to pragma Assert and pragma Loop_Invariant, which the checked profile does
// evaluate, so a variable that only an assertion mentions after a suspension
// point must have its value back when the coroutine is resumed. Otherwise
// the assertion would be evaluated on a zero and fail on valid input. The
// effect is that this back-end may save a local that C does not. That is
// not observable: such a local is, by definition, not read by anything but
// assertions afterwards.
func (h *livenessHelper) doAsserts(r livenesses, asserts []*a.Node, keywords ...t.ID) error {
	for _, o := range asserts {
		o := o.AsAssert()
		for _, k := range keywords {
			if o.Keyword() == k {
				if err := h.doExpr1(r, o.Condition(), false); err != nil {
					return err
				}
			}
		}
	}
	return nil
}
