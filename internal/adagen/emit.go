// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"strings"
)

// This file prints IR (see ir.go) as Ada source text, wrapping lines at
// maxCol columns and indenting by 3, as the project's GNAT style checks
// (-gnatyyM100) require.

const (
	maxCol     = 100
	indentStep = 3
)

func spaces(n int) string { return strings.Repeat(" ", n) }

// isAssociative reports whether a chain "a op b op c" needs no parentheses.
func isAssociative(op string) bool {
	switch op {
	case "+", "*", "and", "or", "xor", "and then", "or else":
		return true
	}
	return false
}

// precedence returns the binding strength of e's outermost operator: Ada's
// logical operators bind least tightly, then the relational ones, then the
// binary adding ones, then the multiplying ones. Everything else is a
// primary (or a unary "not", which binds as tightly as one).
func precedence(e expr) int {
	if _, ok := e.(eRel); ok {
		return 2
	}
	b, ok := e.(eBin)
	if !ok {
		return 9
	}
	switch b.op {
	case "and", "or", "xor", "and then", "or else":
		return 1
	case "=", "/=", "<", "<=", ">", ">=":
		return 2
	case "+", "-":
		return 3
	}
	return 4
}

// needsParens reports whether e needs parentheses as an operand of parent.
// Operators of equal precedence are always parenthesized: Ada forbids mixing
// different logical operators, and chains of one associative operator were
// flattened when the eBin was made.
func needsParens(e expr, parent expr) bool {
	if _, ok := parent.(eUn); ok {
		switch e.(type) {
		case eBin, eRel:
			return true
		}
		return false
	}
	return precedence(e) <= precedence(parent)
}

// flat renders e on one line.
func flat(e expr) string {
	switch e := e.(type) {
	case eRaw:
		return e.s
	case eVar:
		return e.v.name
	case eSel:
		return flat(e.x) + "." + e.field
	case eAttr:
		return flat(e.x) + "'" + e.attr
	case eCall:
		b := strings.Builder{}
		b.WriteString(flat(e.fn))
		for i, o := range e.args {
			if i == 0 {
				b.WriteString(" (")
			} else {
				b.WriteString(", ")
			}
			b.WriteString(flat(o))
		}
		if len(e.args) > 0 {
			b.WriteString(")")
		}
		return b.String()
	case eSlice:
		return flat(e.x) + " (" + flat(e.lo) + " .. " + flat(e.hi) + ")"
	case eQual:
		return e.typ + "'(" + flat(e.x) + ")"
	case eUn:
		return e.op + " " + flatOperand(e.x, e)
	case eBin:
		b := strings.Builder{}
		for i, o := range e.args {
			if i != 0 {
				b.WriteString(" " + e.op + " ")
			}
			b.WriteString(flatOperand(o, e))
		}
		return b.String()
	case eAgg:
		b := strings.Builder{}
		b.WriteString("(")
		for i, o := range e.vals {
			if i != 0 {
				b.WriteString(", ")
			}
			b.WriteString(e.names[i] + " => " + flat(o))
		}
		b.WriteString(")")
		return b.String()
	case eRel:
		return flatOperand(e.l, e) + " " + e.adaOp() + " " + flatOperand(e.r, e)
	case eOut:
		return flat(e.x)
	case eNamed:
		return e.name + " => " + flat(e.x)
	case eIf:
		return "(if " + flat(e.cond) + " then " + flat(e.yes) + " else " + flat(e.no) + ")"
	}
	panic(fmt.Sprintf("adagen: internal error: unknown expr %T", e))
}

func flatOperand(e expr, parent expr) string {
	if needsParens(e, parent) {
		return "(" + flat(e) + ")"
	}
	return flat(e)
}

// wrap renders e as one or more lines. The first line is assumed to start at
// column col (0-based) of some line that the caller is assembling, and to be
// followed by tail more characters (such as a semi-colon). The remaining
// lines carry their own, absolute, indentation.
func wrap(e expr, col int, tail int) []string {
	if s := flat(e); col+len(s)+tail <= maxCol {
		return []string{s}
	}
	switch e := e.(type) {
	case eRel:
		lines := wrapOperand(e.l, e, col, 0)
		prefix := spaces(col+2) + e.adaOp() + " "
		sub := wrapOperand(e.r, e, len(prefix), tail)
		lines = append(lines, prefix+sub[0])
		return append(lines, sub[1:]...)

	case eOut:
		return wrap(e.x, col, tail)

	case eAttr:
		sub := wrap(e.x, col, tail+len(e.attr)+1)
		sub[len(sub)-1] += "'" + e.attr
		return sub

	case eBin:
		lines := wrapOperand(e.args[0], e, col, 0)
		for i, o := range e.args[1:] {
			t := 0
			if i == len(e.args)-2 {
				t = tail
			}
			prefix := spaces(col+2) + e.op + " "
			sub := wrapOperand(o, e, len(prefix), t)
			lines = append(lines, prefix+sub[0])
			lines = append(lines, sub[1:]...)
		}
		return lines

	case eUn:
		sub := wrapOperand(e.x, e, col+len(e.op)+1, tail)
		sub[0] = e.op + " " + sub[0]
		return sub

	case eCall:
		// Prefer the arguments aligned after "Fn (". If that makes a line
		// too long, put the argument list on its own lines.
		fn := flat(e.fn)
		layout := func(ownLines bool) []string {
			lines := []string(nil)
			argCol := col + len(fn) + 2
			if ownLines {
				// (The name may itself be a long chain of indexings.)
				lines = append(lines, wrap(e.fn, col, 0)...)
				argCol = col + 3
				lines = append(lines, spaces(col+2)+"(")
			} else {
				lines = append(lines, fn+" (")
			}
			for i, o := range e.args {
				t := 1 // For the comma or close-paren.
				if i == len(e.args)-1 {
					t += tail
				}
				sub := wrap(o, argCol, t)
				if i == 0 {
					lines[len(lines)-1] += sub[0]
				} else {
					lines = append(lines, spaces(argCol)+sub[0])
				}
				lines = append(lines, sub[1:]...)
				if i == len(e.args)-1 {
					lines[len(lines)-1] += ")"
				} else {
					lines[len(lines)-1] += ","
				}
			}
			return lines
		}
		fits := func(lines []string) bool {
			for i, s := range lines {
				n := len(s)
				if i == 0 {
					n += col
				}
				if i == len(lines)-1 {
					n += tail
				}
				if n > maxCol {
					return false
				}
			}
			return true
		}
		if col+len(fn)+2 <= 48 {
			if lines := layout(false); fits(lines) {
				return lines
			}
		}
		return layout(true)

	case eQual:
		sub := wrap(e.x, col+len(e.typ)+2, tail+1)
		sub[0] = e.typ + "'(" + sub[0]
		sub[len(sub)-1] += ")"
		return sub

	case eAgg:
		lines := []string(nil)
		for i, o := range e.vals {
			prefix := e.names[i] + " => "
			sub := wrap(o, col+1+len(prefix), tail+1)
			if i == 0 {
				lines = append(lines, "("+prefix+sub[0])
			} else {
				lines = append(lines, spaces(col+1)+prefix+sub[0])
			}
			lines = append(lines, sub[1:]...)
			if i == len(e.vals)-1 {
				lines[len(lines)-1] += ")"
			} else {
				lines[len(lines)-1] += ","
			}
		}
		return lines

	case eIf:
		lines := wrap(e.cond, col+4, 0)
		lines[0] = "(if " + lines[0]
		sub := wrap(e.yes, col+6, 0)
		lines = append(lines, spaces(col+1)+"then "+sub[0])
		lines = append(lines, sub[1:]...)
		sub = wrap(e.no, col+6, tail+1)
		lines = append(lines, spaces(col+1)+"else "+sub[0])
		lines = append(lines, sub[1:]...)
		lines[len(lines)-1] += ")"
		return lines

	case eSlice:
		// X
		//   (Lo
		//    .. Hi)
		lines := wrap(e.x, col, 0)
		lo := wrap(e.lo, col+3, 0)
		lines = append(lines, spaces(col+2)+"("+lo[0])
		lines = append(lines, lo[1:]...)
		hi := wrap(e.hi, col+6, tail+1)
		lines = append(lines, spaces(col+3)+".. "+hi[0])
		lines = append(lines, hi[1:]...)
		lines[len(lines)-1] += ")"
		return lines

	case eNamed:
		prefix := e.name + " => "
		sub := wrap(e.x, col+len(prefix), tail)
		sub[0] = prefix + sub[0]
		return sub

	case eSel:
		sub := wrap(e.x, col, tail+1+len(e.field))
		sub[len(sub)-1] += "." + e.field
		return sub
	}
	// Give up: the caller's line will be too long, which GNAT's style checks
	// then report.
	return []string{flat(e)}
}

func wrapOperand(e expr, parent expr, col int, tail int) []string {
	if !needsParens(e, parent) {
		return wrap(e, col, tail)
	}
	sub := wrap(e, col+1, tail+1)
	sub[0] = "(" + sub[0]
	sub[len(sub)-1] += ")"
	return sub
}

// printer accumulates Ada source text.
type printer struct {
	b      strings.Builder
	indent int

	// labelNeedsNull is whether the label being printed is not followed by
	// a statement.
	labelNeedsNull bool
}

func (p *printer) line(s string) {
	if s == "" {
		p.b.WriteString("\n")
		return
	}
	p.b.WriteString(spaces(p.indent))
	p.b.WriteString(s)
	p.b.WriteString("\n")
}

func (p *printer) rawLines(lines []string) {
	for _, s := range lines {
		p.b.WriteString(s)
		p.b.WriteString("\n")
	}
}

func (p *printer) printf(format string, args ...interface{}) {
	p.line(fmt.Sprintf(format, args...))
}

// comment prints text, which may have many lines, as an Ada comment.
func (p *printer) comment(text string) {
	for _, s := range strings.Split(text, "\n") {
		if s == "" {
			p.line("--")
			continue
		}
		// Wrap a line that is too long (a long path or name from the Wuffs
		// source, say) after a space, comma or slash, and indent the rest.
		prefix := "--  "
		for p.indent+len(prefix)+len(s) > maxCol {
			room := maxCol - p.indent - len(prefix)
			cut := strings.LastIndexAny(s[:room], " ,/")
			if cut <= 0 {
				cut = room - 1
			}
			p.line(strings.TrimRight(prefix+s[:cut+1], " "))
			s = s[cut+1:]
			if !strings.HasPrefix(prefix, "--      ") {
				prefix += "    "
			}
		}
		p.line(prefix + s)
	}
}

// exprStmt prints "prefix e suffix" where e may wrap. If e does not fit after
// prefix, and breakAfterPrefix is set, then e starts on its own line.
func (p *printer) exprStmt(prefix string, e expr, suffix string, breakAfterPrefix bool) {
	col := p.indent + len(prefix)
	if s := flat(e); col+len(s)+len(suffix) <= maxCol {
		p.line(prefix + s + suffix)
		return
	}
	if breakAfterPrefix {
		p.line(strings.TrimRight(prefix, " "))
		col = p.indent + 2
		lines := wrap(e, col, len(suffix))
		lines[0] = spaces(col) + lines[0]
		lines[len(lines)-1] += suffix
		p.rawLines(lines)
		return
	}
	lines := wrap(e, col, len(suffix))
	lines[0] = spaces(p.indent) + prefix + lines[0]
	lines[len(lines)-1] += suffix
	p.rawLines(lines)
}

func (p *printer) stmts(ss []stmt) {
	executable := false
	quiet := false
	for i, s := range ss {
		// A label needs a statement to label: the next one, or else null.
		needNull := true
		if i+1 < len(ss) {
			switch ss[i+1].(type) {
			case sComment, sLabel, sResume:
				// Keep it simple: one label per statement.
			case sPragma:
				// A pragma is not a statement.
			default:
				needNull = false
			}
		}
		p.labelNeedsNull = needNull
		// Bracket each run of proved pragmas with a warning Off/On pair.
		pr, ok := s.(sPragma)
		if proved := ok && pr.proved; proved != quiet {
			if proved {
				p.line("pragma Warnings (\"C\");")
			} else {
				p.line("pragma Warnings (\"c\");")
			}
			quiet = proved
		}
		p.stmt(s)
		if _, ok := s.(sComment); !ok {
			executable = true
		}
	}
	if quiet {
		p.line("pragma Warnings (\"c\");")
	}
	if !executable {
		// Ada has no empty sequence of statements.
		p.line("null;")
	}
}

func (p *printer) stmt(s stmt) {
	switch s := s.(type) {
	case sAssign:
		if lhs := flat(s.lhs); p.indent+len(lhs)+len(" :=") <= maxCol {
			p.exprStmt(lhs+" := ", s.rhs, ";", true)
		} else {
			// A left-hand side that needs several lines itself.
			lines := wrap(s.lhs, p.indent, len(" :="))
			lines[0] = spaces(p.indent) + lines[0]
			lines[len(lines)-1] += " :="
			p.rawLines(lines)
			rhs := wrap(s.rhs, p.indent+2, 1)
			rhs[0] = spaces(p.indent+2) + rhs[0]
			rhs[len(rhs)-1] += ";"
			p.rawLines(rhs)
		}

	case sCall:
		p.exprStmt("", s.call, ";", false)

	case sIf:
		for i, br := range s.branches {
			kw := "if "
			if i != 0 {
				kw = "elsif "
			}
			if c := flat(br.cond); p.indent+len(kw)+len(c)+len(" then") <= maxCol {
				p.line(kw + c + " then")
			} else {
				p.exprStmt(kw, br.cond, "", false)
				p.line("then")
			}
			p.indent += indentStep
			p.stmts(br.body)
			p.indent -= indentStep
		}
		if len(s.els) > 0 {
			p.line("else")
			p.indent += indentStep
			p.stmts(s.els)
			p.indent -= indentStep
		}
		p.line("end if;")

	case sLoop:
		if s.name != "" {
			p.line(s.name + " :")
		}
		if s.cond == nil {
			p.line("loop")
		} else if c := flat(s.cond); p.indent+len("while ")+len(c)+len(" loop") <= maxCol {
			p.line("while " + c + " loop")
		} else {
			p.exprStmt("while ", s.cond, "", false)
			p.line("loop")
		}
		p.indent += indentStep
		p.stmts(s.body)
		p.indent -= indentStep
		if s.name != "" {
			p.line("end loop " + s.name + ";")
		} else {
			p.line("end loop;")
		}

	case sExit:
		if s.name != "" {
			p.line("exit " + s.name + ";")
		} else {
			p.line("exit;")
		}

	case sExitWhen:
		p.exprStmt("exit when ", s.cond, ";", false)

	case sLabel:
		p.line("<<" + s.name + ">>")
		if p.labelNeedsNull {
			p.line("null;")
		}

	case sGoto:
		p.line("goto " + s.label + ";")

	case sReturn:
		if s.value == nil {
			p.line("return;")
		} else {
			p.exprStmt("return ", s.value, ";", true)
		}

	case sPragma:
		p.exprStmt("", eCall{eRaw{"pragma " + s.name}, s.args}, ";", false)

	case sComment:
		p.comment(s.text)

	case sResume:
		if !s.labelOnly {
			p.line(fmt.Sprintf("%s := %d;", s.susp.name, s.n))
		}
		p.line("<<" + resumeLabel(s.n) + ">>")
		if p.labelNeedsNull {
			p.line("null;")
		}

	case sCase:
		p.exprStmt("case ", s.sel, " is", false)
		p.indent += indentStep
		for _, arm := range s.arms {
			p.line("when " + arm.value + " =>")
			p.indent += indentStep
			p.stmts(arm.body)
			p.indent -= indentStep
		}
		p.line("when others =>")
		p.indent += indentStep
		p.stmts(s.others)
		p.indent -= indentStep
		p.indent -= indentStep
		p.line("end case;")

	default:
		panic(fmt.Sprintf("adagen: internal error: unknown stmt %T", s))
	}
}

// signature returns the lines of f's subprogram specification, without a
// trailing ";" or " is".
func (f *fn) signature(indent int) (lines []string, oneLine bool) {
	head := ""
	if f.overriding {
		head = "overriding "
	}
	if f.ret == nil {
		head += "procedure " + f.name
	} else {
		head += "function " + f.name
	}

	params := []string(nil)
	mode := ""
	if f.selfInOut {
		mode = "in out "
	}
	params = append(params, f.self.name+" : "+mode+f.recvType)
	for _, o := range f.params {
		mode := ""
		if o.mode != "" {
			mode = o.mode + " "
		}
		params = append(params, o.name+" : "+mode+o.decl)
	}
	ret := ""
	if f.ret != nil {
		ret = " return " + f.ret.name
	}

	all := "(" + strings.Join(params, "; ") + ")"
	if s := head + " " + all + ret; indent+len(s)+len(" is") <= maxCol {
		return []string{spaces(indent) + s}, true
	}
	lines = append(lines, spaces(indent)+head)
	if s := all + ret; indent+2+len(s) <= maxCol {
		return append(lines, spaces(indent+2)+s), false
	}
	for i, o := range params {
		s := spaces(indent+3) + o
		if i == 0 {
			s = spaces(indent+2) + "(" + o
		}
		if i == len(params)-1 {
			s += ")"
		} else {
			s += ";"
		}
		lines = append(lines, s)
	}
	if ret != "" {
		lines = append(lines, spaces(indent+2)+ret)
	}
	return lines, false
}

// spec prints f's declaration.
func (p *printer) fnSpec(f *fn) {
	lines, _ := f.signature(p.indent)
	lines[len(lines)-1] += ";"
	p.rawLines(lines)
}

// fnBody prints f's body.
func (p *printer) fnBody(f *fn) {
	lines, oneLine := f.signature(p.indent)
	if oneLine {
		lines[0] += " is"
		p.rawLines(lines)
	} else {
		p.rawLines(lines)
		p.line("is")
	}
	p.indent += indentStep

	unref := func(v *variable) {
		if v.reads == 0 && v.writes == 0 {
			p.line("pragma Unreferenced (" + v.name + ");")
		}
	}
	unref(f.self)
	for _, o := range f.params {
		unref(o)
		// A writable slice or an I/O buffer is "in out" because of its
		// Wuffs type, whether or not this body writes to it.
		if o.mode != "" && o.writes == 0 && o.reads != 0 {
			p.line("pragma Unmodified (" + o.name + ");")
		}
	}
	for _, o := range f.locals {
		if o.reads == 0 && o.writes == 0 {
			continue
		}
		prefix := o.name + " : "
		if o.writes == 0 {
			prefix += "constant "
		}
		prefix += o.decl
		if o.init == nil {
			p.line(prefix + ";")
		} else {
			p.exprStmt(prefix+" := ", o.init, ";", true)
		}
		if o.reads == 0 || o.quiet {
			p.line("pragma Warnings (Off, " + o.name + ");")
		}
	}

	p.indent -= indentStep
	p.line("begin")
	p.indent += indentStep
	p.stmts(f.body)
	p.indent -= indentStep
	p.line("end " + f.name + ";")
}
