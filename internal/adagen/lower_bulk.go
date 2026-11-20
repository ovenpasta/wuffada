// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"math/big"

	a "github.com/google/wuffs/lang/ast"
)

// This file lowers the bulk methods of slices: s.bulk_memset!(byte_value:
// b), s.bulk_load_host_endian!(src: b) and s.bulk_save_host_endian!(dst: b).
//
// C (cgen builtin.go, writeBuiltinSliceBulkMethodRecv, and the
// wuffs_private_impl__bulk_* functions of fundamental-private.h) treats the
// receiver as len bytes of memory: for a receiver "arr[lo .. hi]" of an
// array of numbers or of arrays of numbers, len is (hi - lo) times the
// element's size in bytes; for a slice of bytes, its length. A load copies
// len bytes from the start of the byte slice b, a save copies them to its
// start, and either copies nothing at all unless 0 < len <= b.len. A memset
// sets every byte. The copies are memmoves.
//
// Here:
//
//   - A receiver whose elements are bytes is a byte view, as any other byte
//     slice. Load and save go through the shell (Wuffs.Runtime), which looks
//     at the addresses and calls the proved operation's form for disjoint
//     arrays or its _Within form.
//   - A receiver "arr[lo .. hi]" (hi given) of an array of uN, N > 8, is
//     the Ada slice arr (lo .. hi - 1), a Wuffs.U16_Array etc. Load and save
//     go through the shell too, whose U16, U32 and U64 forms check that the
//     two arrays do not share storage before they call the proved operation.
//   - A receiver "arr[lo .. hi]" of an array of rows, each an array[R] uN,
//     is a loop over the rows lo .. hi - 1, one call per row, each with its
//     own R * N / 8 bytes of b (a sub-slice of b's handle, so that the
//     checked profile checks it against b's length). For load and save the
//     loop runs only if all of the rows fit in b
//     (Wuffs.Base.Slices.Bulk_Fits), so it is still all or nothing, as in
//     C. Ada has no view of several rows as one array of elements other than
//     an overlay, which this avoids. (Rows of different indexes are separate
//     objects, and a byte slice is never a part of an array of wider
//     numbers, so the row order does not matter. For rows of bytes, copies
//     row by row give the result of C's one memmove too: a Wuffs byte slice
//     of such an array lies within one row, so it can only hold enough bytes
//     for one row, and a one-row copy is that memmove.)
//
// The receiver must be "x[lo .. hi]" with hi given (lo may be omitted), as
// in upstream's C back-end, which rejects everything else. Deeper nesting
// (rows of rows) is rejected too.

func isBulkMethod(name string) bool {
	switch name {
	case "bulk_memset", "bulk_load_host_endian", "bulk_save_host_endian":
		return true
	}
	return false
}

// bulkMethod lowers a bulk method call whose receiver recv is a slice.
func (l *lowerer) bulkMethod(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	if len(args) != 1 {
		return val{}, fmt.Errorf("call %q: wrong number of arguments", n.Str(l.g.tm))
	}
	inner := recv.MType().Inner()
	arrExpr, loExpr, hiExpr, ok := recv.IsSlice()
	if !ok || hiExpr == nil {
		// Upstream's C back-end (writeBuiltinSliceBulkMethodRecv) handles
		// only these forms, and rejects the others ("TODO: bulk_memset for
		// general expressions"): so does this one, so that everything that
		// it generates can be checked against upstream's C.
		return val{}, errNotYet("%q: a bulk method whose receiver is not \"x[lo .. hi]\" (with hi)", n.Str(l.g.tm))
	}
	if inner.Decorator() == 0 && uintBits(inner.QID()) == 8 {
		return l.bulkBytes(n, recv, name, args)
	}
	if !arrExpr.MType().IsEitherArrayType() {
		return val{}, errNotYet("%q: a bulk method on a slice of %q that is not a part of an array",
			n.Str(l.g.tm), inner.Str(l.g.tm))
	}
	arr, err := l.expr(arrExpr)
	if err != nil {
		return val{}, err
	}
	if arr.typ == nil || arr.typ.kind != kArray {
		return val{}, fmt.Errorf("%q: the receiver is not a slice of an array", n.Str(l.g.tm))
	}
	lo := expr(raw("0"))
	if loExpr != nil {
		if lo, err = l.index(loExpr); err != nil {
			return val{}, err
		}
	}
	hi, err := l.index(hiExpr)
	if err != nil {
		return val{}, err
	}
	vs, err := l.argValues(n, args, 1)
	if err != nil {
		return val{}, err
	}
	arg := vs[0]

	elem := arr.typ.elem
	rowLen := (*big.Int)(nil)
	if elem.kind == kArray {
		rowLen = elem.length
		elem = elem.elem
	}
	if elem.kind != kNum {
		return val{}, errNotYet("%q: a bulk method on a slice of %q", n.Str(l.g.tm), inner.Str(l.g.tm))
	}
	bits := elem.bits
	sizeOf := map[int]string{8: "1", 16: "2", 32: "4", 64: "8"}[bits]
	suffix := fmt.Sprintf("_U%d", bits)

	if name != "bulk_save_host_endian" {
		// The receiver is written.
		if !arr.variable {
			return val{}, fmt.Errorf("%q on a constant receiver", n.Str(l.g.tm))
		}
		markWritten(arr.e)
	}
	if name == "bulk_memset" {
		if err := l.numArg(n, arg, 8); err != nil {
			return val{}, err
		}
	} else if !arg.typ.isSlice() {
		return val{}, fmt.Errorf("%q: the argument is not a slice of bytes", n.Str(l.g.tm))
	}

	if rowLen == nil {
		// One array of numbers: its Ada slice. (bits > 8 here.)
		view := eSlice{arr.e, lo, indexMinus1(hi)}
		switch name {
		case "bulk_memset":
			l.pre = append(l.pre, sCall{callNamed(slicesPkg+".Bulk_Memset"+suffix,
				"Dst", expr(view), "Byte_Value", arg.e)})
		case "bulk_load_host_endian":
			src, err := l.apart(arg, false, arr.e)
			if err != nil {
				return val{}, err
			}
			l.pre = append(l.pre, sCall{callNamed("Wuffs.Runtime.Bulk_Load_Host_Endian"+suffix,
				"Dst", expr(view), "Src", src.e)})
		default:
			dst, err := l.apart(arg, true, arr.e)
			if err != nil {
				return val{}, err
			}
			l.pre = append(l.pre, sCall{callNamed("Wuffs.Runtime.Bulk_Save_Host_Endian"+suffix,
				"Dst", dst.e, "Src", expr(view))})
		}
		return val{}, nil
	}

	// Rows: k runs from lo to hi - 1. The bounds (and a memset's value) are
	// evaluated once, before anything is copied, as C evaluates its pointer
	// and length once: an expression that reads the receiver must not see
	// the rows that this very call has already written.
	loOnce, hiOnce := eVar{l.newTemp(typIndex)}, eVar{l.newTemp(typIndex)}
	l.pre = append(l.pre, sAssign{loOnce, lo}, sAssign{hiOnce, hi})
	lo, hi = loOnce, hiOnce
	if name == "bulk_memset" {
		valueOnce := eVar{l.newTemp(typU8)}
		l.pre = append(l.pre, sAssign{valueOnce, arg.e})
		arg.e = valueOnce
	}
	k := eVar{l.newTemp(typIndex)}
	row := eCall{arr.e, []expr{k}}
	loop := func(body ...stmt) []stmt {
		return []stmt{
			sAssign{k, lo},
			sLoop{cond: rel("<", k, hi), body: append(body, sAssign{k, bin("+", k, raw("1"))})},
		}
	}
	if name == "bulk_memset" {
		l.pre = append(l.pre, loop(sCall{callNamed(slicesPkg+".Bulk_Memset"+suffix,
			"Dst", expr(row), "Byte_Value", arg.e)})...)
		return val{}, nil
	}

	// The byte slice, in a handle: each row gets its part of it.
	writable := name == "bulk_save_host_endian"
	hv, err := l.toHandle(arg, writable)
	if err != nil {
		return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
	}
	h := eVar{l.newTemp(hv.typ)}
	rowBytes := new(big.Int).Mul(rowLen, big.NewInt(int64(bits/8)))
	rowIndex := expr(k)
	if loExpr != nil {
		rowIndex = bin("-", k, lo)
	}
	// The row's part of the byte slice, as a sub-slice of the handle (whose
	// precondition the checked profile evaluates) and then a view.
	pt := eVar{l.newTemp(hv.typ)}
	first := bin("*", rowIndex, raw(rowBytes.String()))
	sub := sAssign{pt, callNamed("Wuffs.Runtime.Subslice_IJ", "S", h, "I", first,
		"J", bin("+", first, raw(rowBytes.String())))}
	part := eSlice{eSel{pt, "Base"}, eSel{pt, "First"}, call("Wuffs.Runtime.Last", pt)}
	var call1 stmt
	if writable {
		call1 = sCall{callNamed("Wuffs.Runtime.Bulk_Save_Host_Endian"+suffix, "Dst", expr(part), "Src", expr(row))}
	} else {
		call1 = sCall{callNamed("Wuffs.Runtime.Bulk_Load_Host_Endian"+suffix, "Dst", expr(row), "Src", expr(part))}
	}
	count := bin("*", bin("-", hi, lo), raw(rowLen.String()))
	if loExpr == nil {
		count = bin("*", hi, raw(rowLen.String()))
	}
	l.pre = append(l.pre,
		sAssign{h, hv.e},
		sIf{branches: []ifBranch{{
			callNamed(slicesPkg+".Bulk_Fits", "Count", count, "Size", raw(sizeOf), "Bytes_Length", eSel{h, "Length"}),
			loop(sub, call1),
		}}})
	return val{}, nil
}

// bulkBytes lowers a bulk method whose receiver is a slice of bytes.
func (l *lowerer) bulkBytes(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	rv, err := l.expr(recv)
	if err != nil {
		return val{}, err
	}
	if rv.typ == nil || !rv.typ.isSlice() {
		return val{}, errNotYet("method call %q on a receiver of type %q", n.Str(l.g.tm), recv.MType().Str(l.g.tm))
	}
	vs, err := l.argValues(n, args, 1)
	if err != nil {
		return val{}, err
	}
	switch name {
	case "bulk_memset":
		if err := l.numArg(n, vs[0], 8); err != nil {
			return val{}, err
		}
		b, err := l.toBytes(rv, true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		l.pre = append(l.pre, sCall{callNamed(slicesPkg+".Bulk_Memset_U8", "Dst", b.e, "Byte_Value", vs[0].e)})
		return val{}, nil

	case "bulk_load_host_endian":
		dst, err := l.toBytes(rv, true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		src, err := l.otherOperand(n, vs[0], rootOf(dst))
		if err != nil {
			return val{}, err
		}
		l.pre = append(l.pre, sCall{callNamed("Wuffs.Runtime.Bulk_Load_Host_Endian_U8",
			"Dst", dst.e, "Src", src.e)})
		return val{}, nil

	case "bulk_save_host_endian":
		if !vs[0].typ.isSlice() {
			return val{}, fmt.Errorf("%q: the argument is not a slice of bytes", n.Str(l.g.tm))
		}
		dst, err := l.toBytes(vs[0], true)
		if err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		src, err := l.otherOperand(n, rv, rootOf(dst))
		if err != nil {
			return val{}, err
		}
		l.pre = append(l.pre, sCall{callNamed("Wuffs.Runtime.Bulk_Save_Host_Endian_U8",
			"Dst", dst.e, "Src", src.e)})
		return val{}, nil
	}
	return val{}, fmt.Errorf("internal error: bulk method %q", name)
}

// rootOf returns what otherOperand compares roots with, for a byte view.
func rootOf(v val) expr {
	if v.arr != nil {
		return v.arr
	}
	return v.e
}

// apart converts the byte slice v (an operand of an operation whose other
// array is a part of the variable that other is a part of) to an Ada array
// view. If v is visibly a part of the same variable, it goes through a
// slice handle, for the reason given at sliceActual.
func (l *lowerer) apart(v val, writable bool, other expr) (val, error) {
	if v.arr != nil {
		if r := rootVariable(v.arr); r != nil && r == rootVariable(other) {
			h, err := l.toHandle(v, writable)
			if err != nil {
				return val{}, err
			}
			return l.toBytes(h, writable)
		}
	}
	return l.toBytes(v, writable)
}
