// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

// This file lowers method calls: of Wuffs functions (of this package or of a
// used one) and of the built-in methods of the base types, which become
// calls into the proved base library (Wuffs.Base.*) or, where two arrays or
// a slice handle are involved, into its shell (Wuffs.Runtime).

// isIOMethodCall reports whether n calls a built-in method of an io_reader
// or io_writer.
func isIOMethodCall(n *a.Expr) bool {
	if n.Operator() != a.ExprOperatorCall {
		return false
	}
	return n.LHS().AsExpr().LHS().AsExpr().MType().IsIOType()
}

// call lowers a method call.
func (l *lowerer) call(n *a.Expr) (val, error) {
	method := n.LHS().AsExpr()
	recv := method.LHS().AsExpr()
	recvTyp := recv.MType()
	args := n.Args()
	name := method.Ident().Str(l.g.tm)

	switch {
	case recvTyp.IsIOType():
		rv, err := l.expr(recv)
		if err != nil {
			return val{}, err
		}
		if rv.io == nil {
			return val{}, errNotYet("method call %q on something other than an I/O argument", n.Str(l.g.tm))
		}
		return l.ioMethod(n, rv.io, name, args)

	case recvTyp.IsEitherSliceType():
		return l.sliceMethod(n, recv, name, args)

	case recvTyp.IsStatus():
		fn := map[string]string{
			"is_ok":         "Wuffs.Is_Ok",
			"is_error":      "Wuffs.Is_Error",
			"is_suspension": "Wuffs.Is_Suspension",
			"is_note":       "Wuffs.Is_Note",
			"is_complete":   basePkg + ".Is_Complete",
		}[name]
		if fn == "" || len(args) != 0 {
			break
		}
		rv, err := l.expr(recv)
		if err != nil {
			return val{}, err
		}
		return val{e: call(fn, rv.e), typ: typBool}, nil

	case recvTyp.Decorator() == 0 && recvTyp.QID() == t.QID{t.IDBase, t.IDUtility}:
		return l.utilityMethod(n, name, args)

	case recvTyp.Decorator() == 0 && recvTyp.QID() == t.QID{t.IDBase, t.IDPixelFormat}:
		return l.pixelFormatMethod(n, recv, name, args)

	case recvTyp.Decorator() == 0 && recvTyp.QID() == t.QID{t.IDBase, t.IDPixelSwizzler}:
		return l.swizzlerMethod(n, recv, name, args)

	case recvTyp.Decorator() == t.IDTable:
		return l.tableMethod(n, recv, name, args)

	case (recvTyp.Decorator() == t.IDPtr || recvTyp.Decorator() == t.IDNptr) &&
		recvTyp.Inner().Decorator() == 0 && recvTyp.Inner().QID()[0] == t.IDBase:
		return l.pointerMethod(n, recv, name, args)

	case recvTyp.Decorator() == 0 && uintBits(recvTyp.QID()) != 0:
		return l.numMethod(n, recv, method.Ident(), args)
	}

	// A Wuffs function, on this or on a field of this.
	p := recvTyp
	if d := p.Decorator(); d == t.IDPtr || d == t.IDNptr {
		p = p.Inner()
	}
	if p.Decorator() == 0 && p.QID()[0] != t.IDBase {
		return l.userCall(n, recv, method.Ident(), args)
	}
	return val{}, errNotYet("method call %q on a receiver of type %q", n.Str(l.g.tm), recvTyp.Str(l.g.tm))
}

// argValues lowers the arguments of a built-in method call, in order.
func (l *lowerer) argValues(n *a.Expr, args []*a.Node, want int) ([]val, error) {
	if len(args) != want {
		return nil, fmt.Errorf("call %q: wrong number of arguments", n.Str(l.g.tm))
	}
	ret := []val(nil)
	for _, o := range args {
		v, err := l.expr(o.AsArg().Value())
		if err != nil {
			return nil, err
		}
		if v.typ == nil {
			return nil, fmt.Errorf("argument %q has no value", o.AsArg().Value().Str(l.g.tm))
		}
		ret = append(ret, v)
	}
	return ret, nil
}

// numArg checks that v is a bits-wide unsigned integer (or a literal).
func (l *lowerer) numArg(n *a.Expr, v val, bits int) error {
	if err := checkNum(v, bits); err != nil {
		return fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
	}
	return nil
}

// widen converts e, of the fromBits-wide modular type, to the toBits-wide
// one.
func widen(e expr, fromBits int, toBits int) val {
	if fromBits != toBits {
		e = call(numType(toBits).name, e)
	}
	return val{e: e, typ: numType(toBits)}
}

// procResult runs the procedure call (a call into the base library whose
// last parameter, called outName, is an "out" one) before the current
// statement, and returns the temporary that receives the result.
func (l *lowerer) procResult(fn string, typ *adaType, outName string, namesAndArgs ...interface{}) val {
	tmp := eVar{l.newTemp(typ)}
	namesAndArgs = append(namesAndArgs, outName, expr(eOut{tmp}))
	l.pre = append(l.pre, sCall{callNamed(fn, namesAndArgs...)})
	return val{e: tmp, typ: typ}
}

var (
	peekRE     = regexp.MustCompile(`^peek_u(8|16|24|32|40|48|56|64)(le|be)?(?:_as_u(8|16|32|64))?$`)
	readRE     = regexp.MustCompile(`^read_u(8|16|24|32|40|48|56|64)(le|be)?(?:_as_u(8|16|32|64))?$`)
	peekPokeRE = regexp.MustCompile(`^(peek|poke)_u(8|16|24|32|40|48|56|64)(le|be)?$`)
	writeRE    = regexp.MustCompile(`^write_u(8|16|24|32|40|48|56|64)(le|be)?_fast$`)
)

// widthOf returns the width of the modular type that holds an n-bit value.
func widthOf(n int) int {
	switch {
	case n <= 8:
		return 8
	case n <= 16:
		return 16
	case n <= 32:
		return 32
	}
	return 64
}

// endianName returns e.g. "Peek_U32LE" for ("Peek_U", "32", "le").
func endianName(prefix string, bits string, endian string) string {
	return prefix + bits + strings.ToUpper(endian)
}

// ioMethod lowers a built-in method of an io_reader or io_writer argument.
// See the method table in ada/src/base/wuffs-base-io.ads.
func (l *lowerer) ioMethod(n *a.Expr, io *ioArg, name string, args []*a.Node) (val, error) {
	data, meta := io.data, expr(eVar{io.meta})

	// The one method that does not need a cursor (C: a_src->meta.closed).
	if name == "is_closed" && !io.writer && len(args) == 0 {
		return val{e: eSel{meta, "Closed"}, typ: typBool}, nil
	}
	if io.cursor == nil {
		return val{}, fmt.Errorf("internal error: no cursor for %q", n.Str(l.g.tm))
	}
	c := expr(eVar{io.cursor})
	cName := "R"
	if io.writer {
		cName = "W"
	}

	// Methods of both.
	switch name {
	case "length", "mark", "position":
		if len(args) != 0 {
			break
		}
		return val{e: call(ioPkg+"."+mangle(name), c), typ: typU64}, nil
	case "can_undo_byte":
		if len(args) != 0 {
			break
		}
		return val{e: call(ioPkg+".Can_Undo_Byte", c), typ: typBool}, nil
	case "undo_byte":
		if len(args) != 0 {
			break
		}
		l.pre = append(l.pre, sCall{call(ioPkg+".Undo_Byte", c)})
		return val{}, nil
	case "count_since":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 64); err != nil {
			return val{}, err
		}
		return val{e: callNamed(ioPkg+".Count_Since", cName, c, "Mark", vs[0].e), typ: typU64}, nil
	case "since":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 64); err != nil {
			return val{}, err
		}
		// The bytes between the mark and the cursor, as a view of the
		// buffer's array.
		lo := callNamed(ioPkg+".Since_Offset", cName, c, "Mark", vs[0].e)
		hi := bin("+", lo, callNamed(ioPkg+".Since_Length", cName, c, "Mark", vs[0].e))
		v := bytesVal(data, lo, hi, io.writer, false)
		v.e = eSlice{data,
			callNamed("Wuffs.Runtime.Since_First", "Data", data, cName, c, "Mark", vs[0].e),
			callNamed("Wuffs.Runtime.Since_Last", "Data", data, cName, c, "Mark", vs[0].e)}
		return v, nil
	}

	if !io.writer {
		return l.readerMethod(n, io, name, args)
	}
	return l.writerMethod(n, io, name, args)
}

func (l *lowerer) readerMethod(n *a.Expr, io *ioArg, name string, args []*a.Node) (val, error) {
	data, c := io.data, expr(eVar{io.cursor})

	if m := peekRE.FindStringSubmatch(name); m != nil && len(args) == 0 && (m[1] == "8") == (m[2] == "") {
		bits, _ := strconv.Atoi(m[1])
		from := widthOf(bits)
		to := from
		if m[3] != "" {
			to, _ = strconv.Atoi(m[3])
		}
		if to < from {
			return val{}, fmt.Errorf("bad method %q", name)
		}
		return widen(call(ioPkg+"."+endianName("Peek_U", m[1], m[2]), data, c), from, to), nil
	}

	switch name {
	case "limited_copy_u32_to_slice":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		if !vs[1].typ.isSlice() {
			return val{}, fmt.Errorf("%q: not a slice", n.Str(l.g.tm))
		}
		// Through a handle: the destination may be a part of the receiver
		// or of an argument, and the shell looks at the addresses.
		h, err := l.toHandle(vs[1], true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		dst, err := l.toBytes(h, true)
		if err != nil {
			return val{}, err
		}
		return l.procResult("Wuffs.Runtime.Reader_Limited_Copy_U32_To_Slice", typU32, "N",
			"Data", data, "R", expr(eOut{c}), "Up_To", vs[0].e, "Dst", dst.e), nil

	case "peek_u8_at":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		return val{e: callNamed(ioPkg+".Peek_U8_At", "Data", data, "R", c, "Offset", vs[0].e), typ: typU8}, nil

	case "skip_u32_fast":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		// The second argument, worst_case, is for the Wuffs compiler's
		// proof only.
		l.pre = append(l.pre, sCall{callNamed(ioPkg+".Skip_U32_Fast", "R", c, "Actual", vs[0].e)})
		return val{}, nil

	case "skip", "skip_u32":
		return l.readerSkip(n, io, name, args)
	}

	if m := readRE.FindStringSubmatch(name); m != nil && len(args) == 0 && (m[1] == "8") == (m[2] == "") {
		return l.readerRead(n, io, m)
	}
	return val{}, errNotYet("io_reader method %q", name)
}

// readerSkip lowers the coroutine methods skip?(n) and skip_u32?(n), as the
// C back-end's writeBuiltinQuestionCall does.
func (l *lowerer) readerSkip(n *a.Expr, io *ioArg, name string, args []*a.Node) (val, error) {
	if !l.fi.coroutine {
		return val{}, fmt.Errorf("%q outside of a coroutine", n.Str(l.g.tm))
	}
	c := expr(eVar{io.cursor})
	vs, err := l.argValues(n, args, 1)
	if err != nil {
		return val{}, err
	}
	bits := 64
	if name == "skip_u32" {
		bits = 32
	}
	if err := l.numArg(n, vs[0], bits); err != nil {
		return val{}, err
	}
	l.g.useType[64] = true

	if vs[0].cv != nil && vs[0].cv.Cmp(one) == 0 {
		l.pre = append(l.pre,
			l.suspPoint(),
			sIf{branches: []ifBranch{{bin("=", call(ioPkg+".Length", c), raw("0")),
				l.suspendWith("Suspension_Short_Read")}}},
			sCall{callNamed(ioPkg+".Skip_U32_Fast", "R", c, "Actual", raw("1"))})
		return val{}, nil
	}

	scratch := l.scratchField()
	count := vs[0].e
	if vs[0].typ.kind == kNum && vs[0].typ.bits != 64 {
		count = call("Wuffs.U64", count)
	}
	done := eVar{l.newTemp(typBool)}
	l.pre = append(l.pre,
		sAssign{scratch, count},
		l.suspPoint(),
		sCall{callNamed(ioPkg+".Skip", "R", eOut{c}, "Scratch", eOut{scratch}, "Done", eOut{done})},
		sIf{branches: []ifBranch{{eUn{"not", done}, l.suspendWith("Suspension_Short_Read")}}})
	return val{}, nil
}

// readerRead lowers the coroutine methods read_u8?(), read_u32le?(),
// read_u16be_as_u32?() and so on. m is the match of readRE.
func (l *lowerer) readerRead(n *a.Expr, io *ioArg, m []string) (val, error) {
	if !l.fi.coroutine {
		return val{}, fmt.Errorf("%q outside of a coroutine", n.Str(l.g.tm))
	}
	data, c := io.data, expr(eVar{io.cursor})
	bits, _ := strconv.Atoi(m[1])
	from := widthOf(bits)
	to := from
	if m[3] != "" {
		to, _ = strconv.Atoi(m[3])
	}
	if to < from {
		return val{}, fmt.Errorf("bad method %q", n.Str(l.g.tm))
	}
	l.g.useType[64] = true
	length := call(ioPkg+".Length", c)
	shortRead := sIf{branches: []ifBranch{{bin("=", length, raw("0")), l.suspendWith("Suspension_Short_Read")}}}

	if bits == 8 {
		// C: suspension point; if (iop == io2) suspend; t = *iop++.
		tmp := eVar{l.newTemp(typU8)}
		l.pre = append(l.pre, l.suspPoint(), shortRead,
			sCall{callNamed(ioPkg+".Read_U8", "Data", data, "R", eOut{c}, "V", eOut{tmp})})
		return widen(tmp, 8, to), nil
	}

	// C (writeReadUxxAsUyy): the fast path if all the bytes are there, else
	// one byte at a time into the scratch word, suspending whenever there
	// are none.
	tmp := eVar{l.newTemp(numType(from))}
	scratch := l.scratchField()
	done := eVar{l.newTemp(typBool)}
	value := eVar{l.newTemp(typU64)}
	step := "Read_Step_LE"
	if m[2] == "be" {
		step = "Read_Step_BE"
	}
	result := expr(value)
	if from != 64 {
		result = call(numType(from).name, result)
	}
	l.pre = append(l.pre, sIf{
		branches: []ifBranch{{
			bin(">=", length, raw(fmt.Sprint(bits/8))),
			[]stmt{
				sAssign{tmp, call(ioPkg+"."+endianName("Peek_U", m[1], m[2]), data, c)},
				sCall{callNamed(ioPkg+".Skip_U32_Fast", "R", c, "Actual", raw(fmt.Sprint(bits/8)))},
			},
		}},
		els: []stmt{
			sAssign{scratch, raw("0")},
			l.suspPoint(),
			sLoop{body: []stmt{
				shortRead,
				sCall{callNamed(ioPkg+"."+step,
					"Data", data, "R", eOut{c}, "Scratch", eOut{scratch},
					"Last_Shift", raw(fmt.Sprint(bits-8)), "Done", eOut{done}, "Value", eOut{value})},
				sExitWhen{done},
			}},
			sAssign{tmp, result},
		},
	})
	return widen(tmp, from, to), nil
}

func (l *lowerer) writerMethod(n *a.Expr, io *ioArg, name string, args []*a.Node) (val, error) {
	data, c := io.data, expr(eVar{io.cursor})
	// Whatever follows may write to the buffer (those that do not are
	// harmless to count).
	io.markWritten()

	switch name {
	case "history_length", "history_position":
		if len(args) != 0 {
			break
		}
		return val{e: call(ioPkg+"."+mangle(name), c), typ: typU64}, nil

	case "write_u8":
		// The coroutine method write_u8?(a). C: scratch = a; suspension
		// point; if (iop == io2) suspend; *iop++ = (uint8_t)scratch.
		if !l.fi.coroutine {
			return val{}, fmt.Errorf("%q outside of a coroutine", n.Str(l.g.tm))
		}
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 8); err != nil {
			return val{}, err
		}
		l.g.useType[64] = true
		scratch := l.scratchField()
		a0 := vs[0].e
		if vs[0].typ.kind == kNum {
			a0 = call("Wuffs.U64", a0)
		}
		l.pre = append(l.pre,
			sAssign{scratch, a0},
			l.suspPoint(),
			sIf{branches: []ifBranch{{bin("=", call(ioPkg+".Length", c), raw("0")),
				l.suspendWith("Suspension_Short_Write")}}},
			sCall{callNamed(ioPkg+".Write_U8_Fast", "Data", data, "W", c,
				"V", call("Wuffs.U8", bin("and", scratch, raw("16#FF#"))))})
		return val{}, nil

	case "copy_from_slice":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		src, err := l.otherOperand(n, vs[0], data)
		if err != nil {
			return val{}, err
		}
		return l.procResult("Wuffs.Runtime.Writer_Copy_From_Slice", typU64, "N",
			"Data", data, "W", c, "Src", src.e), nil

	case "limited_copy_u32_from_slice":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		src, err := l.otherOperand(n, vs[1], data)
		if err != nil {
			return val{}, err
		}
		return l.procResult("Wuffs.Runtime.Writer_Limited_Copy_U32_From_Slice", typU32, "N",
			"Data", data, "W", c, "Up_To", vs[0].e, "Src", src.e), nil

	case "limited_copy_u32_from_reader":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		r := vs[1].io
		if r == nil || r.writer || r.cursor == nil {
			return val{}, errNotYet("%q with a reader that is not an argument", n.Str(l.g.tm))
		}
		return l.procResult("Wuffs.Runtime.Writer_Limited_Copy_U32_From_Reader", typU32, "N",
			"Data", data, "W", c, "Up_To", vs[0].e,
			"Src_Data", r.data, "R", expr(eVar{r.cursor})), nil

	case "limited_copy_u32_from_history",
		"limited_copy_u32_from_history_fast",
		"limited_copy_u32_from_history_8_byte_chunks_fast",
		"limited_copy_u32_from_history_8_byte_chunks_distance_1_fast":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		for _, v := range vs {
			if err := l.numArg(n, v, 32); err != nil {
				return val{}, err
			}
		}
		// The LZ77 copies stay within the writer's own array.
		return l.procResult(ioPkg+"."+mangle(name), typU32, "N",
			"Data", data, "W", c, "Up_To", vs[0].e, "Distance", vs[1].e), nil
	}

	if m := writeRE.FindStringSubmatch(name); m != nil && (m[1] == "8") == (m[2] == "") {
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		bits, _ := strconv.Atoi(m[1])
		if err := l.numArg(n, vs[0], widthOf(bits)); err != nil {
			return val{}, err
		}
		l.pre = append(l.pre, sCall{callNamed(ioPkg+"."+endianName("Write_U", m[1], m[2])+"_Fast",
			"Data", data, "W", c, "V", vs[0].e)})
		return val{}, nil
	}
	return val{}, errNotYet("io_writer method %q", name)
}

// bytesFirst returns the Ada index of the first element of the array view b
// (a result of toBytes).
func bytesFirst(b val) expr {
	return eAttr{b.e, "First"}
}

// sliceActual converts a slice-typed value to the actual parameter of a
// call of a Wuffs function.
//
// The rule: the only slice that is passed directly as an Ada array is one of
// the caller's own slice parameters, whole. Every other slice (a part of a
// field of the receiver, of a local array, of a parameter, of an I/O buffer)
// goes through a slice handle in a temporary and is passed as a view of what
// that handle designates.
//
// The reason is that the callee also gets the receiver, often as "in out",
// and the slice is often a part of the receiver. Wuffs (and C) allow that:
// the callee sees its own writes through either name. Ada passes both by
// reference too, but GNAT rejects a call in which it can see that an actual
// overlaps a writable one (an error for a function, a warning for a
// procedure, which this project treats as an error). Through a handle,
// which is what the slice is in C anyway, there is nothing for it to see,
// and the semantics are C's.
func (l *lowerer) sliceActual(v val, writable bool) (val, error) {
	switch v.typ.kind {
	case kBytes, kBytesVar:
		if x, ok := v.e.(eVar); ok && x.v.kind == varParam {
			return l.toBytes(v, writable)
		}
		h, err := l.toHandle(v, writable)
		if err != nil {
			return val{}, err
		}
		return l.toBytes(h, writable)
	}
	return l.toBytes(v, writable)
}

// rootVariable returns the variable that the name e is a part of, or nil.
func rootVariable(e expr) *variable {
	for {
		switch x := e.(type) {
		case eVar:
			return x.v
		case eSel:
			e = x.x
		case eCall:
			e = x.fn
		case eSlice:
			e = x.x
		default:
			return nil
		}
	}
}

// otherOperand converts the source slice of a two-array operation whose
// destination is (a part of) the array dst. If both are parts of one
// variable (say, two fields of the receiver), the source goes through a
// slice handle, for the reason given at sliceActual.
func (l *lowerer) otherOperand(n *a.Expr, v val, dst expr) (val, error) {
	if !v.typ.isSlice() {
		return val{}, fmt.Errorf("%q: argument is not a slice of bytes", n.Str(l.g.tm))
	}
	if v.arr != nil {
		if r := rootVariable(v.arr); r != nil && r == rootVariable(dst) {
			h, err := l.toHandle(v, false)
			if err != nil {
				return val{}, err
			}
			return l.toBytes(h, false)
		}
	}
	return l.toBytes(v, false)
}

// sliceArg converts a slice-typed argument of a built-in method to a
// read-only Ada array view.
func (l *lowerer) sliceArg(n *a.Expr, v val) (val, error) {
	if !v.typ.isSlice() {
		return val{}, fmt.Errorf("%q: argument is not a slice of bytes", n.Str(l.g.tm))
	}
	return l.toBytes(v, false)
}

// sliceMethod lowers a built-in method of a slice.
func (l *lowerer) sliceMethod(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	if rv.typ == nil || !rv.typ.isSlice() {
		return val{}, errNotYet("method call %q on a receiver of type %q", n.Str(l.g.tm), recv.MType().Str(l.g.tm))
	}
	writable := rv.typ.kind == kSliceU8 || rv.typ.kind == kBytesVar

	switch name {
	case "length":
		if len(args) != 0 {
			break
		}
		switch rv.typ.kind {
		case kBytes, kBytesVar:
			return val{e: call("Wuffs.U64", eAttr{rv.e, "Length"}), typ: typU64}, nil
		}
		return val{e: call("Wuffs.U64", eSel{rv.e, "Length"}), typ: typU64}, nil

	case "suffix":
		// (Upstream's C back-end does not implement "prefix", so there is
		// nothing to check an implementation of it against.)
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 64); err != nil {
			return val{}, err
		}
		h, err := l.toHandle(rv, writable)
		if err != nil {
			return val{}, err
		}
		return val{e: callNamed("Wuffs.Runtime."+mangle(name), "S", h.e, "Up_To", vs[0].e), typ: h.typ}, nil

	case "copy_from_slice":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if !vs[0].typ.isSlice() {
			return val{}, fmt.Errorf("%q: argument is not a slice of bytes", n.Str(l.g.tm))
		}
		src := vs[0]
		dst, err := l.toBytes(rv, true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		if dst.arr != nil && src.arr != nil && flat(dst.arr) == flat(src.arr) {
			// Both are visibly parts of one Ada array: call the base
			// library's same-array form directly. (For everything else, the
			// run-time shell decides.)
			first := func(v val) expr {
				f := expr(eAttr{v.arr, "First"})
				if v.zeroBased {
					f = raw("0")
				}
				if v.lo == nil {
					return f
				}
				if v.zeroBased {
					return v.lo
				}
				return bin("+", f, v.lo)
			}
			length := func(v val) expr {
				hi := v.hi
				if hi == nil {
					hi = eAttr{v.arr, "Length"}
				}
				if v.lo == nil {
					return hi
				}
				return bin("-", hi, v.lo)
			}
			return l.procResult(slicesPkg+".Copy_Within", typU64, "N",
				"Data", dst.arr,
				"Dst_First", first(dst), "Dst_Length", length(dst),
				"Src_First", first(src), "Src_Length", length(src)), nil
		}
		dstRoot := dst.arr
		if dstRoot == nil {
			dstRoot = dst.e
		}
		if src, err = l.otherOperand(n, src, dstRoot); err != nil {
			return val{}, err
		}
		return l.procResult("Wuffs.Runtime.Copy_From_Slice", typU64, "N", "Dst", dst.e, "Src", src.e), nil
	}
	if m := peekPokeRE.FindStringSubmatch(name); m != nil && (m[2] == "8") == (m[3] == "") {
		// Wuffs.Base.Endian, at the slice's first element. The Wuffs
		// compiler has proved that the slice is long enough.
		bits, _ := strconv.Atoi(m[2])
		fn := endianPkg + "." + endianName(mangle(m[1])+"_U", m[2], m[3])
		if m[1] == "peek" {
			if len(args) != 0 {
				return val{}, fmt.Errorf("call %q: wrong number of arguments", n.Str(l.g.tm))
			}
			b, err := l.toBytes(rv, false)
			if err != nil {
				return val{}, err
			}
			return val{e: callNamed(fn, "Data", b.e, "Pos", bytesFirst(b)), typ: numType(widthOf(bits))}, nil
		}
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], widthOf(bits)); err != nil {
			return val{}, err
		}
		b, err := l.toBytes(rv, true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		l.pre = append(l.pre, sCall{callNamed(fn, "Data", b.e, "Pos", bytesFirst(b), "V", vs[0].e)})
		return val{}, nil
	}
	return val{}, errNotYet("slice method %q", name)
}

// utilityMethod lowers a method of base.utility.
func (l *lowerer) utilityMethod(n *a.Expr, name string, args []*a.Node) (val, error) {
	switch name {
	case "cpu_arch_is_32_bit":
		if len(args) != 0 {
			break
		}
		return val{e: raw(targetPkg + ".CPU_Arch_Is_32_Bit"), typ: typBool}, nil

	case "make_optional_u63":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		if vs[0].typ.kind != kBool {
			return val{}, fmt.Errorf("%q: has_value is not a bool", n.Str(l.g.tm))
		}
		if err := l.numArg(n, vs[1], 64); err != nil {
			return val{}, err
		}
		return val{
			e:   callNamed(intsPkg+".Make_Optional_U63", "Has_Value", vs[0].e, "Value", vs[1].e),
			typ: typOptionalU63,
		}, nil

	case "empty_slice_u8":
		if len(args) != 0 {
			break
		}
		return bytesVal(raw("Wuffs.Runtime.Empty_Bytes_Variable"), nil, nil, true, false), nil

	case "make_pixel_format":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		return val{e: callNamed(formatsPkg+".Make_Pixel_Format", "Repr", vs[0].e), typ: typPixelFormat}, nil

	case "make_rect_ie_u32":
		vs, err := l.argValues(n, args, 4)
		if err != nil {
			return val{}, err
		}
		for _, v := range vs {
			if err := l.numArg(n, v, 32); err != nil {
				return val{}, err
			}
		}
		return val{
			e: callNamed(rangesPkg+".Make_Rect_IE_U32",
				"Min_Incl_X", vs[0].e, "Min_Incl_Y", vs[1].e, "Max_Excl_X", vs[2].e, "Max_Excl_Y", vs[3].e),
			typ: typRectIEU32,
		}, nil

	case "make_range_ii_u64":
		vs, err := l.argValues(n, args, 2)
		if err != nil {
			return val{}, err
		}
		for _, v := range vs {
			if err := l.numArg(n, v, 64); err != nil {
				return val{}, err
			}
		}
		return val{
			e:   callNamed(rangesPkg+".Make_Range_II_U64", "Min_Incl", vs[0].e, "Max_Incl", vs[1].e),
			typ: typRangeIIU64,
		}, nil
	}
	return val{}, errNotYet("base.utility method %q", name)
}

// numMethod lowers a built-in method of a numeric type: a call into
// Wuffs.Base.Ints.
func (l *lowerer) numMethod(n *a.Expr, recv *a.Expr, method t.ID, args []*a.Node) (val, error) {
	bits := uintBits(recv.MType().QID())
	fn, argBits, argName := "", bits, "Y"
	switch method {
	case t.IDLowBits:
		fn, argBits, argName = "Low_Bits", 32, "N"
	case t.IDHighBits:
		fn, argBits, argName = "High_Bits", 32, "N"
	case t.IDMin:
		fn = "Min"
	case t.IDMax:
		fn = "Max"
	}
	if fn == "" || len(args) != 1 {
		return val{}, errNotYet("method call %q on a receiver of type %q", n.Str(l.g.tm), recv.MType().Str(l.g.tm))
	}
	vs, err := l.operands(n, recv.AsNode(), args[0].AsArg().Value().AsNode())
	if err != nil {
		return val{}, err
	}
	if err := l.numArg(n, vs[0], bits); err != nil {
		return val{}, err
	}
	if err := l.numArg(n, vs[1], argBits); err != nil {
		return val{}, err
	}
	return val{
		e:   callNamed(fmt.Sprintf("%s.%s_U%d", intsPkg, fn, bits), "X", vs[0].e, argName, vs[1].e),
		typ: numType(bits),
	}, nil
}

// userCall lowers a call of a Wuffs function: a method of the current
// function's receiver ("this.f(etc)") or of one of its fields
// ("this.field.f(etc)"), the latter possibly of a used package.
func (l *lowerer) userCall(n *a.Expr, recv *a.Expr, method t.ID, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	if rv.typ == nil || rv.typ.kind != kStruct || rv.e == nil {
		return val{}, errNotYet("method call %q", n.Str(l.g.tm))
	}
	st := rv.typ.st
	pkg := t.ID(0)
	if st.pkg != nil {
		pkg = st.pkg.id
	}
	if method == t.IDReset && len(args) == 0 {
		// C: the struct's initialize function (with
		// WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED for a field
		// of this, which leaves stale bytes that nothing may depend on;
		// Initialize zeroes them).
		if !rv.variable {
			return val{}, fmt.Errorf("call %q on a constant receiver", n.Str(l.g.tm))
		}
		l.f.self.writes++
		name := "Initialize"
		if st.pkg != nil {
			name = st.pkg.adaName + ".Initialize"
		}
		l.pre = append(l.pre, sCall{call(name, eOut{rv.e})})
		return val{}, nil
	}
	callee := l.g.funcs[t.QQID{pkg, st.ast.QID()[1], method}]
	if callee == nil {
		return val{}, errNotYet("method call %q", n.Str(l.g.tm))
	}
	if callee.skipped {
		return val{}, fmt.Errorf("call %q of a function that was skipped as it needs a cpu_arch capability", n.Str(l.g.tm))
	}
	if callee.sigErr != nil {
		return val{}, fmt.Errorf("call %q: %v", n.Str(l.g.tm), callee.sigErr)
	}
	f := callee.ir
	if callee.dispatch != nil {
		f = callee.dispatch
	}
	if len(args) != len(callee.args) {
		return val{}, fmt.Errorf("call %q: wrong number of arguments", n.Str(l.g.tm))
	}
	if callee.coroutine && !l.fi.coroutine {
		return val{}, fmt.Errorf("coroutine call %q outside of a coroutine", n.Str(l.g.tm))
	}
	if f.selfInOut {
		if !rv.variable {
			return val{}, fmt.Errorf("call %q of an impure function on a constant receiver", n.Str(l.g.tm))
		}
		l.f.self.writes++
	}

	// Parameter names and values, in order.
	names, values := []string(nil), []expr(nil)
	for i, o := range args {
		arg := o.AsArg().Value()
		v, err := l.expr(arg)
		if err != nil {
			return val{}, err
		}
		if v.typ == nil {
			return val{}, fmt.Errorf("argument %q has no value", arg.Str(l.g.tm))
		}
		want := callee.args[i]
		switch want.typ.kind {
		case kIOReader, kIOWriter:
			if v.io == nil || v.typ.kind != want.typ.kind {
				return val{}, errNotYet("argument %q: an I/O value other than an I/O argument", arg.Str(l.g.tm))
			}
			names = append(names, want.v.name, want.meta.name)
			values = append(values, v.io.data, eVar{v.io.meta})
			v.io.meta.writes++
			if v.io.writer {
				v.io.markWritten()
			}
			// The callee builds its own cursor from the meta, and leaves
			// its position there. C: writeSaveExprDerivedVars and
			// writeLoadExprDerivedVars.
			if v.io.cursor != nil {
				cursor, meta := eVar{v.io.cursor}, eVar{v.io.meta}
				l.pre = append(l.pre, sCall{call(ioPkg+".Save", meta, cursor)})
				l.post = append(l.post, sCall{call(ioPkg+".Reload", cursor, meta)})
			}
			continue
		case kBytes, kBytesVar:
			if !v.typ.isSlice() {
				return val{}, fmt.Errorf("argument %q is not a slice", arg.Str(l.g.tm))
			}
			if v, err = l.sliceActual(v, want.typ.kind == kBytesVar); err != nil {
				return val{}, fmt.Errorf("argument %q: %v", arg.Str(l.g.tm), err)
			}
		case kNum:
			if err := checkNum(v, want.typ.bits); err != nil {
				return val{}, fmt.Errorf("argument %q: %v", arg.Str(l.g.tm), err)
			}
		case kBool, kStatus:
			if v.typ.kind != want.typ.kind {
				return val{}, fmt.Errorf("argument %q has the wrong type", arg.Str(l.g.tm))
			}
		case kOpaque:
			if v.typ != want.typ {
				return val{}, fmt.Errorf("argument %q has the wrong type", arg.Str(l.g.tm))
			}
		case kNptr:
			// The object and its "null" flag. For a literal nullptr, an
			// object that nothing looks at and True.
			names = append(names, want.v.name, want.null.name)
			switch {
			case v.isNull:
				l.nTemps++
				dummy := l.newLocal(fmt.Sprintf("%sNull_%d", prefixGen, l.nTemps), want.typ, nil)
				dummy.quiet = true
				dummy.writes++
				values = append(values, eVar{dummy}, raw("True"))
			case v.parg != nil && v.parg.typ == want.typ:
				v.parg.v.writes++
				values = append(values, eVar{v.parg.v}, eVar{v.parg.null})
			default:
				return val{}, errNotYet("argument %q: a pointer other than a pointer argument or nullptr", arg.Str(l.g.tm))
			}
			continue
		case kPixBuf:
			if v.parg == nil || v.typ.kind != kPixBuf {
				return val{}, errNotYet("argument %q: a pixel buffer other than a pixel buffer argument", arg.Str(l.g.tm))
			}
			names = append(names, want.v.name, want.pixels.name, want.palette.name)
			values = append(values, eVar{v.parg.v}, eVar{v.parg.pixels}, eVar{v.parg.palette})
			v.parg.pixels.writes++
			v.parg.palette.writes++
			continue
		default:
			return val{}, fmt.Errorf("internal error: unexpected parameter type")
		}
		names = append(names, want.v.name)
		values = append(values, v.e)
	}

	// Named association as soon as there are two parameters to mix up.
	es := []expr{rv.e}
	for i, e := range values {
		if len(values) >= 2 {
			e = eNamed{names[i], e}
		}
		es = append(es, e)
	}
	ret := val{e: eCall{eRaw{f.name}, es}}
	if f.ret != nil {
		ret.typ = f.ret
	}
	return ret, nil
}

// pixelFormatMethod lowers a method of base.pixel_format.
func (l *lowerer) pixelFormatMethod(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	if rv.typ != typPixelFormat || len(args) != 0 {
		return val{}, errNotYet("method call %q", n.Str(l.g.tm))
	}
	switch name {
	case "bits_per_pixel":
		return val{e: call(formatsPkg+".Bits_Per_Pixel", rv.e), typ: typU32}, nil
	case "default_background_color":
		return val{e: call(formatsPkg+".Default_Background_Color", rv.e), typ: typU32}, nil
	}
	return val{}, errNotYet("base.pixel_format method %q", name)
}

// pointerMethod lowers a method of a pointer-typed argument: an image
// config, a frame config or a pixel buffer.
func (l *lowerer) pointerMethod(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	arg := rv.parg
	if arg == nil {
		return val{}, errNotYet("method call %q on something other than a pointer argument", n.Str(l.g.tm))
	}
	obj := expr(eVar{arg.v})

	switch {
	case arg.typ == typNptrImageConfig && name == "set":
		// The Wuffs compiler has proved that the pointer is not null here.
		// Even if it were, the object exists.
		vs, err := l.argValues(n, args, 6)
		if err != nil {
			return val{}, err
		}
		for i, bits := range []int{32, 32, 32, 32, 64} {
			if err := l.numArg(n, vs[i], bits); err != nil {
				return val{}, err
			}
		}
		if vs[5].typ.kind != kBool {
			return val{}, fmt.Errorf("%q: first_frame_is_opaque is not a bool", n.Str(l.g.tm))
		}
		arg.v.writes++
		l.pre = append(l.pre, sCall{callNamed(formatsPkg+".Set",
			"C", expr(eOut{obj}),
			"Pixfmt_Repr", vs[0].e, "Pixsub_Repr", vs[1].e, "Width", vs[2].e, "Height", vs[3].e,
			"First_Frame_IO_Position", vs[4].e, "First_Frame_Is_Opaque", vs[5].e)})
		return val{}, nil

	case arg.typ == typNptrFrameConfig && name == "set":
		vs, err := l.argValues(n, args, 8)
		if err != nil {
			return val{}, err
		}
		if vs[0].typ != typRectIEU32 || vs[5].typ.kind != kBool || vs[6].typ.kind != kBool {
			return val{}, fmt.Errorf("%q: wrong argument types", n.Str(l.g.tm))
		}
		for i, bits := range map[int]int{1: 64, 2: 64, 3: 64, 4: 8, 7: 32} {
			if err := l.numArg(n, vs[i], bits); err != nil {
				return val{}, err
			}
		}
		// C converts the disposal to its enumeration type, likewise.
		disposal := vs[4].e
		if vs[4].typ.kind == kNum {
			disposal = call(formatsPkg+".Animation_Disposal", disposal)
		}
		arg.v.writes++
		l.pre = append(l.pre, sCall{callNamed(formatsPkg+".Set",
			"C", expr(eOut{obj}),
			"Bounds", vs[0].e, "Duration", vs[1].e, "Index", vs[2].e, "IO_Position", vs[3].e,
			"Disposal", disposal, "Opaque_Within_Bounds", vs[5].e,
			"Overwrite_Instead_Of_Blend", vs[6].e, "Background_Color", vs[7].e)})
		return val{}, nil

	case arg.typ == typNptrMoreInfo && name == "set":
		vs, err := l.argValues(n, args, 5)
		if err != nil {
			return val{}, err
		}
		for i, bits := range []int{32, 32, 64, 64, 64} {
			if err := l.numArg(n, vs[i], bits); err != nil {
				return val{}, err
			}
		}
		arg.v.writes++
		l.pre = append(l.pre, sCall{callNamed("Wuffs.Runtime.Set",
			"M", expr(eOut{obj}), "Flavor", vs[0].e, "W", vs[1].e, "X", vs[2].e, "Y", vs[3].e, "Z", vs[4].e)})
		return val{}, nil

	case arg.typ.kind == kPixBuf:
		switch name {
		case "palette_or_else":
			// The palette if there is one, else the fallback: a handle.
			vs, err := l.argValues(n, args, 1)
			if err != nil {
				return val{}, err
			}
			if !vs[0].typ.isSlice() {
				return val{}, fmt.Errorf("%q: the fallback is not a slice", n.Str(l.g.tm))
			}
			palette := expr(eVar{arg.palette})
			length := callNamed("Wuffs.Runtime.Palette_Length", "PB", obj, "Palette", palette)
			h1, err := l.toHandle(bytesVal(palette, nil, length, true, false), true)
			if err != nil {
				return val{}, err
			}
			h2, err := l.toHandle(vs[0], true)
			if err != nil {
				return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
			}
			tmp := eVar{l.newTemp(typSliceU8)}
			l.pre = append(l.pre, sIf{
				branches: []ifBranch{{rel("/=", length, raw("0")), []stmt{sAssign{tmp, h1.e}}}},
				els:      []stmt{sAssign{tmp, h2.e}},
			})
			return val{e: tmp, typ: typSliceU8}, nil
		case "pixel_format":
			if len(args) != 0 {
				break
			}
			return val{e: call(buffersPkg+".Get_Pixel_Format", obj), typ: typPixelFormat}, nil
		case "palette":
			if len(args) != 0 {
				break
			}
			// The first 1024 bytes of the palette array, or nothing.
			palette := expr(eVar{arg.palette})
			return bytesVal(palette, nil,
				callNamed("Wuffs.Runtime.Palette_Length", "PB", obj, "Palette", palette), true, false), nil
		case "plane":
			vs, err := l.argValues(n, args, 1)
			if err != nil {
				return val{}, err
			}
			if err := l.numArg(n, vs[0], 32); err != nil {
				return val{}, err
			}
			// Only plane 0 has a known array (the pixels).
			if vs[0].cv == nil || vs[0].cv.Sign() != 0 {
				return val{}, errNotYet("%q: a plane other than plane 0", n.Str(l.g.tm))
			}
			return val{
				e:        callNamed(buffersPkg+".Plane", "PB", obj, "P", vs[0].e),
				typ:      typTable,
				tableArr: arg.pixels,
			}, nil
		}
	}
	return val{}, errNotYet("method call %q", n.Str(l.g.tm))
}

// tableMethod lowers a method of a table.
func (l *lowerer) tableMethod(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	if rv.typ == nil || rv.typ.kind != kTable || rv.tableArr == nil {
		return val{}, errNotYet("method call %q on a table that is not tied to an array", n.Str(l.g.tm))
	}
	arr := expr(eVar{rv.tableArr})
	switch name {
	case "width", "height", "stride":
		if len(args) != 0 {
			break
		}
		field := strings.ToUpper(name[:1]) + name[1:]
		return val{e: call("Wuffs.U64", eSel{rv.e, field}), typ: typU64}, nil

	case "subtable":
		vs, err := l.argValues(n, args, 4)
		if err != nil {
			return val{}, err
		}
		for _, v := range vs {
			if err := l.numArg(n, v, 64); err != nil {
				return val{}, err
			}
		}
		// Wuffs' subtable takes inclusive maxima: C's generated code calls
		// wuffs_base__table_u8__subtable_ij with them as they are (cgen
		// builtin.go maps the method to the _ij function), so do the same.
		tmp := eVar{l.newTemp(typTable)}
		l.pre = append(l.pre, sCall{callNamed(buffersPkg+".Subtable",
			"T", rv.e, "IX", vs[0].e, "IY", vs[1].e, "JX", vs[2].e, "JY", vs[3].e,
			"Length", expr(eAttr{arr, "Length"}), "Result", expr(eOut{tmp}))})
		return val{e: tmp, typ: typTable, tableArr: rv.tableArr}, nil

	case "row_u32":
		vs, err := l.argValues(n, args, 1)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		// Pixel_Buffers.Row_U32 is total: the range that it returns always
		// lies within the array, and is empty if there is no such row.
		first, count := eVar{l.newTemp(typOffset)}, eVar{l.newTemp(typIndex)}
		l.pre = append(l.pre, sCall{callNamed(buffersPkg+".Row_U32",
			"T", rv.e, "Y", vs[0].e, "Length", expr(eAttr{arr, "Length"}),
			"First", expr(eOut{first}), "Count", expr(eOut{count}))})
		rv.tableArr.writes++
		return bytesVal(arr, first, bin("+", first, count), true, false), nil
	}
	return val{}, errNotYet("table method %q", name)
}

// swizzlerMethod lowers a method of a base.pixel_swizzler field: a call
// into the shell, which checks the operands' aliasing before it calls the
// proved code (see wuffs-runtime.ads).
func (l *lowerer) swizzlerMethod(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	if rv.typ == nil || rv.typ.kind != kSwizzler || rv.e == nil {
		return val{}, errNotYet("method call %q", n.Str(l.g.tm))
	}
	// view converts a slice argument to an array view, through a handle
	// unless it is visibly not a part of the receiver.
	view := func(v val, writable bool) (val, error) {
		if !v.typ.isSlice() {
			return val{}, fmt.Errorf("%q: argument is not a slice of bytes", n.Str(l.g.tm))
		}
		if v.arr != nil {
			if r := rootVariable(v.arr); r != nil && r.kind == varSelf {
				h, err := l.toHandle(v, writable)
				if err != nil {
					return val{}, err
				}
				return l.toBytes(h, writable)
			}
		}
		return l.toBytes(v, writable)
	}

	switch name {
	case "prepare":
		vs, err := l.argValues(n, args, 5)
		if err != nil {
			return val{}, err
		}
		if vs[0].typ != typPixelFormat || vs[2].typ != typPixelFormat || vs[4].typ != typPixelBlend {
			return val{}, fmt.Errorf("%q: wrong argument types", n.Str(l.g.tm))
		}
		dstPalette, err := view(vs[1], true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		srcPalette, err := view(vs[3], false)
		if err != nil {
			return val{}, err
		}
		if !rv.variable {
			return val{}, fmt.Errorf("%q on a constant receiver", n.Str(l.g.tm))
		}
		l.f.self.writes++
		return l.procResult("Wuffs.Runtime.Swizzler_Prepare", typStatus, "Result",
			"S", expr(eOut{rv.e}), "Dst_Pixfmt", vs[0].e, "Dst_Palette", dstPalette.e,
			"Src_Pixfmt", vs[2].e, "Src_Palette", srcPalette.e, "Blend", vs[4].e), nil

	case "swizzle_interleaved_from_slice", "swizzle_interleaved_from_reader":
		vs, err := l.argValues(n, args, 3)
		if err != nil {
			return val{}, err
		}
		dst, err := view(vs[0], true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		dstPalette, err := view(vs[1], false)
		if err != nil {
			return val{}, err
		}
		if name == "swizzle_interleaved_from_slice" {
			src, err := view(vs[2], false)
			if err != nil {
				return val{}, err
			}
			return l.procResult("Wuffs.Runtime.Swizzle_Interleaved_From_Slice", typU64, "N",
				"S", rv.e, "Dst", dst.e, "Dst_Palette", dstPalette.e, "Src", src.e), nil
		}
		r := vs[2].io
		if r == nil || r.writer || r.cursor == nil {
			return val{}, errNotYet("%q with a reader that is not an argument", n.Str(l.g.tm))
		}
		return l.procResult("Wuffs.Runtime.Swizzle_Interleaved_From_Reader", typU64, "N",
			"S", rv.e, "Dst", dst.e, "Dst_Palette", dstPalette.e,
			"Src_Data", r.data, "R", expr(eOut{eVar{r.cursor}})), nil
	}
	switch name {
	case "swizzle_interleaved_transparent_black":
		vs, err := l.argValues(n, args, 3)
		if err != nil {
			return val{}, err
		}
		dst, err := view(vs[0], true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		dstPalette, err := view(vs[1], false)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[2], 64); err != nil {
			return val{}, err
		}
		return l.procResult("Wuffs.Runtime.Swizzle_Interleaved_Transparent_Black", typU64, "N",
			"S", rv.e, "Dst", dst.e, "Dst_Palette", dstPalette.e, "Num_Pixels", vs[2].e), nil

	case "limited_swizzle_u32_interleaved_from_reader":
		vs, err := l.argValues(n, args, 4)
		if err != nil {
			return val{}, err
		}
		if err := l.numArg(n, vs[0], 32); err != nil {
			return val{}, err
		}
		dst, err := view(vs[1], true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		dstPalette, err := view(vs[2], false)
		if err != nil {
			return val{}, err
		}
		r := vs[3].io
		if r == nil || r.writer || r.cursor == nil {
			return val{}, errNotYet("%q with a reader that is not an argument", n.Str(l.g.tm))
		}
		return l.procResult("Wuffs.Runtime.Limited_Swizzle_U32_Interleaved_From_Reader", typU64, "N",
			"S", rv.e, "Up_To_Num_Pixels", vs[0].e, "Dst", dst.e, "Dst_Palette", dstPalette.e,
			"Src_Data", r.data, "R", expr(eOut{eVar{r.cursor}})), nil
	}
	return val{}, errNotYet("base.pixel_swizzler method %q", name)
}

// markWritten records that the buffer's data is written.
func (io *ioArg) markWritten() {
	if io.arg != nil {
		io.arg.v.writes++
	}
}
