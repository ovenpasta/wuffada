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
