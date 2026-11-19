// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"strings"
)

// adaReserved is the set of Ada 2022 reserved words, lower-cased.
var adaReserved = map[string]bool{}

func init() {
	for _, s := range strings.Fields(`
		abort abs abstract accept access aliased all and array at begin body
		case constant declare delay delta digits do else elsif end entry
		exception exit for function generic goto if in interface is limited
		loop mod new not null of or others out overriding package parallel
		pragma private procedure protected raise range record rem renames
		requeue return reverse select separate some subtype synchronized
		tagged task terminate then type until use when while with xor`) {
		adaReserved[s] = true
	}
}

// adaTaken is the set of lower-cased names that generated package-level
// declarations must not hide, because generated code refers to them.
var adaTaken = map[string]bool{
	"wuffs": true, "interfaces": true, "standard": true, "boolean": true,
	"true": true, "false": true, "natural": true, "integer": true,
	"self": true, "initialize": true, "magic": true, "std": true,
}

// Ada has one flat, case-insensitive namespace per declarative region, and a
// subprogram's locals hide the package's declarations. Generated identifiers
// are therefore partitioned by their first underscore-separated piece, so
// that no two categories can ever collide or hide one another, whatever the
// Wuffs source calls things:
//
//   - "V_": a Wuffs local variable.
//   - "A_": a Wuffs argument (a formal parameter).
//   - "M_": the mutable local copy of an argument that the body assigns to.
//   - "F_": a struct field (a record component).
//   - "G_": anything that the generator invents: temporaries, loop names,
//     labels, loop indexes, named subtypes and array types.
//   - anything else: a Wuffs package-level name (const, func, struct), via
//     mangleGlobal, which escapes (with "W_") a Wuffs name whose own first
//     piece is one of the above or "W".
//
// Status constants start with "Error_", "Note_" or "Suspension_". Those, and
// the few fixed names in adaTaken, share the package-level namespace with
// Wuffs names; gen.declareName makes any clash there an error.
const (
	prefixLocal   = "V_"
	prefixArg     = "A_"
	prefixArgCopy = "M_"
	prefixField   = "F_"
	prefixGen     = "G_"
	prefixEscape  = "W_"
)

// mangleGlobal converts a Wuffs package-level identifier to an Ada one that
// is outside of the namespaces of locals, arguments, fields and generator
// inventions.
func mangleGlobal(s string) string {
	m := mangle(s)
	first := m
	if i := strings.IndexByte(m, '_'); i >= 0 {
		first = m[:i]
	}
	switch strings.ToLower(first) {
	case "v", "a", "m", "f", "g", "w":
		return prefixEscape + m
	}
	return m
}

// mangle converts a Wuffs identifier (snake_case, possibly with consecutive,
// leading or trailing underscores, none of which Ada allows) to an Ada
// identifier fragment: each underscore-separated piece gets an upper-case
// first letter, and an empty piece becomes "U".
//
// The result is not necessarily a valid stand-alone identifier (it may be a
// reserved word or start with a digit): callers either add one of the
// prefixes above or go through mangleGlobal and gen.declareName.
func mangle(s string) string {
	pieces := strings.Split(s, "_")
	for i, p := range pieces {
		if p == "" {
			pieces[i] = "U"
		} else if c := p[0]; 'a' <= c && c <= 'z' {
			pieces[i] = string(c-0x20) + p[1:]
		}
	}
	return strings.Join(pieces, "_")
}

// baseStatusExceptions lists the base statuses whose Ada constant in
// Wuffs.Base is not what mangleMessage derives from the message.
var baseStatusExceptions = map[string]string{
	"@I/O redirect":     "Note_IO_Redirect",
	"#bad I/O position": "Error_Bad_IO_Position",
	"#disabled by WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST": "Error_Disabled_By_Dst_Pixel_Format_Enable_Allowlist",
}

// baseStatusName returns the name of the Wuffs.Base constant for the base
// status whose message (with its leading '@', '$' or '#') is msg.
func baseStatusName(msg string) (string, error) {
	if s, ok := baseStatusExceptions[msg]; ok {
		return s, nil
	}
	return mangleMessage(msg)
}

// mangleMessage converts a Wuffs status message such as "#unsupported
// option" to an Ada identifier such as "Error_Unsupported_Option".
func mangleMessage(msg string) (string, error) {
	prefix := "Note_"
	if msg != "" {
		switch msg[0] {
		case '#':
			prefix, msg = "Error_", msg[1:]
		case '$':
			prefix, msg = "Suspension_", msg[1:]
		case '@':
			msg = msg[1:]
		}
	}
	b := []byte(nil)
	upper := true
	for i := 0; i < len(msg); i++ {
		c := msg[i]
		switch {
		case 'a' <= c && c <= 'z':
			if upper {
				c -= 0x20
			}
			b = append(b, c)
			upper = false
		case ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9'):
			b = append(b, c)
			upper = false
		default:
			if len(b) > 0 && b[len(b)-1] != '_' {
				b = append(b, '_')
			}
			upper = true
		}
	}
	for len(b) > 0 && b[len(b)-1] == '_' {
		b = b[:len(b)-1]
	}
	if len(b) == 0 {
		return "", fmt.Errorf("cannot derive an Ada name from status message %q", msg)
	}
	return prefix + string(b), nil
}

func isValidAdaIdent(s string) bool {
	if s == "" || adaReserved[strings.ToLower(s)] {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z'):
		case '0' <= c && c <= '9':
			if i == 0 {
				return false
			}
		case c == '_':
			if i == 0 || i == len(s)-1 || s[i-1] == '_' {
				return false
			}
		default:
			return false
		}
	}
	return true
}

// declareName reserves a package-level Ada name, failing on an invalid or
// already used one. Ada identifiers are case-insensitive.
func (g *gen) declareName(name string, what string) error {
	lower := strings.ToLower(name)
	if !isValidAdaIdent(name) {
		return fmt.Errorf("%s: %q is not usable as an Ada identifier", what, name)
	}
	if adaTaken[lower] || lower == strings.ToLower(g.adaPkgSimpleName) {
		return fmt.Errorf("%s: Ada name %q collides with a name that generated code relies on", what, name)
	}
	if prev, ok := g.names[lower]; ok {
		return fmt.Errorf("%s: Ada name %q collides with %s (Ada is case-insensitive)", what, name, prev)
	}
	g.names[lower] = what
	return nil
}

// The functions below are a backstop. The naming scheme above is meant to
// make clashes impossible; these check, for every declarative region that
// the generator emits other than the package itself (which declareName
// covers), that every name is a valid Ada identifier and that no two are the
// same (ignoring case), so that a mistake in the scheme is a generation
// error and never an Ada compilation error.

type nameSet struct {
	what string
	seen map[string]string
}

func (s *nameSet) add(name string, what string) error {
	if !isValidAdaIdent(name) {
		return fmt.Errorf("internal error: %s %q is not a valid Ada identifier", what, name)
	}
	lower := strings.ToLower(name)
	if prev, ok := s.seen[lower]; ok {
		return fmt.Errorf("internal error: %s: the name %q is used for %s and for %s", s.what, name, prev, what)
	}
	if s.seen == nil {
		s.seen = map[string]string{}
	}
	s.seen[lower] = what
	return nil
}

// checkRecordNames checks the components of the record for s.
func checkRecordNames(s *structInfo) error {
	names := &nameSet{what: "record components"}
	if err := names.add("Magic", "the magic component"); err != nil {
		return err
	}
	if s.hasActiveCoroutine {
		if err := names.add(activeCoroutineField, "the active coroutine component"); err != nil {
			return err
		}
	}
	for _, f := range s.fields {
		if f.typ.kind == kUtility {
			continue
		}
		if err := names.add(f.name, "a field"); err != nil {
			return err
		}
	}
	for _, f := range s.extra {
		if err := names.add(f.name, "coroutine state"); err != nil {
			return err
		}
	}
	return nil
}

// checkSubprogramNames checks the names that f's body declares: its
// parameters, local variables, loop names and labels (which, in Ada, are
// all declared in the subprogram's one declarative region).
func checkSubprogramNames(f *fn) error {
	names := &nameSet{what: "subprogram " + f.name}
	if err := names.add(f.self.name, "the receiver"); err != nil {
		return err
	}
	for _, o := range f.params {
		if err := names.add(o.name, "a parameter"); err != nil {
			return err
		}
	}
	for _, o := range f.locals {
		// (An unused local is not declared, but its name is still taken.)
		if err := names.add(o.name, "a local variable"); err != nil {
			return err
		}
	}
	var visit func(ss []stmt) error
	visit = func(ss []stmt) error {
		for _, s := range ss {
			switch s := s.(type) {
			case sLabel:
				if err := names.add(s.name, "a label"); err != nil {
					return err
				}
			case sResume:
				if err := names.add(resumeLabel(s.n), "a resume label"); err != nil {
					return err
				}
			case sLoop:
				if s.name != "" {
					if err := names.add(s.name, "a loop name"); err != nil {
						return err
					}
				}
				if err := visit(s.body); err != nil {
					return err
				}
			case sIf:
				for _, br := range s.branches {
					if err := visit(br.body); err != nil {
						return err
					}
				}
				if err := visit(s.els); err != nil {
					return err
				}
			case sCase:
				for _, arm := range s.arms {
					if err := visit(arm.body); err != nil {
						return err
					}
				}
				if err := visit(s.others); err != nil {
					return err
				}
			}
		}
		return nil
	}
	return visit(f.body)
}
