// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"bytes"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/google/wuffs/lang/parse"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

// This file handles Wuffs "use" declarations.
//
// The Wuffs compiler resolves `use "std/deflate"` by reading an interface
// file, gen/wuffs/std/deflate.wuffs, that upstream's "wuffs gen" command
// writes: the used package's public declarations, without function bodies
// or struct fields. UseResolver makes the same text directly from the used
// package's sources (it is a port of genWuffs in the Wuffs repository's
// cmd/wuffs/gen.go), so that a fresh checkout is enough.
//
// The generator then parses that text once more, for the Ada names and
// signatures of what the used package declares.

// UseResolver returns a function that resolves a use path such as
// "std/deflate.wuffs" to the interface text of the package whose sources are
// the ".wuffs" files of the directory wuffsRoot/std/deflate.
func UseResolver(wuffsRoot string) func(usePath string) ([]byte, error) {
	return func(usePath string) ([]byte, error) {
		dir := filepath.Join(wuffsRoot, filepath.FromSlash(strings.TrimSuffix(usePath, ".wuffs")))
		entries, err := os.ReadDir(dir)
		if err != nil {
			return nil, fmt.Errorf("cannot resolve use path %q: %v", usePath, err)
		}
		names := []string(nil)
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".wuffs") {
				names = append(names, e.Name())
			}
		}
		sort.Strings(names)
		if len(names) == 0 {
			return nil, fmt.Errorf("cannot resolve use path %q: no .wuffs files in %s", usePath, dir)
		}

		tm := &t.Map{}
		out := &bytes.Buffer{}
		fmt.Fprintf(out, "// Interface of %q, derived from its sources by wuffs-ada.\n\n", usePath)
		for _, name := range names {
			src, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				return nil, err
			}
			tokens, _, err := t.Tokenize(tm, name, src)
			if err != nil {
				return nil, err
			}
			f, err := parse.Parse(tm, name, tokens, &parse.Options{AllowDoubleUnderscoreNames: true})
			if err != nil {
				return nil, err
			}
			if err := writeInterface(out, tm, f); err != nil {
				return nil, err
			}
		}
		return out.Bytes(), nil
	}
}

// writeInterface writes the public declarations of f, as upstream's genWuffs
// does.
func writeInterface(out *bytes.Buffer, tm *t.Map, f *a.File) error {
	for _, n := range f.TopLevelDecls() {
		switch n.Kind() {
		case a.KConst:
			n := n.AsConst()
			if !n.Public() {
				continue
			}
			fmt.Fprintf(out, "pub const %s : %s = %v\n",
				n.QID().Str(tm), n.XType().Str(tm), n.Value().Str(tm))

		case a.KFunc:
			n := n.AsFunc()
			if !n.Public() {
				continue
			}
			if n.Receiver().IsZero() {
				return fmt.Errorf("a free-standing function in a used package is not supported")
			}
			fmt.Fprintf(out, "pub func %s.%s%v(", n.Receiver().Str(tm), n.FuncName().Str(tm), n.Effect())
			for i, field := range n.In().Fields() {
				field := field.AsField()
				if i > 0 {
					fmt.Fprintf(out, ", ")
				}
				fmt.Fprintf(out, "%s: %s", field.Name().Str(tm), field.XType().Str(tm))
			}
			fmt.Fprintf(out, ") ")
			if o := n.Out(); o != nil {
				fmt.Fprintf(out, "%s ", o.Str(tm))
			}
			fmt.Fprintf(out, "{ }\n")

		case a.KStatus:
			n := n.AsStatus()
			if !n.Public() {
				continue
			}
			fmt.Fprintf(out, "pub status %s\n", n.QID().Str(tm))

		case a.KStruct:
			n := n.AsStruct()
			if !n.Public() {
				continue
			}
			fmt.Fprintf(out, "pub struct %s", n.QID().Str(tm))
			if n.Classy() {
				fmt.Fprintf(out, "?")
			}
			if imps := n.Implements(); len(imps) > 0 {
				fmt.Fprintf(out, " implements ")
				for i, imp := range imps {
					if i > 0 {
						fmt.Fprintf(out, ", ")
					}
					fmt.Fprintf(out, "%s", imp.AsTypeExpr().Str(tm))
				}
			}
			fmt.Fprintf(out, "()\n")
		}
	}
	return nil
}

// usedPkg is a package that the one being generated uses.
type usedPkg struct {
	id      t.ID   // E.g. the ID of "deflate".
	adaName string // E.g. "Wuffs.Std.Deflate".
	structs map[t.ID]*structInfo
}

func (g *gen) analyzeUses() error {
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			if n.Kind() != a.KUse {
				continue
			}
			n := n.AsUse()
			usePath, ok := t.Unescape(n.Path().Str(g.tm))
			if !ok {
				return fmt.Errorf("bad use path %s", n.Path().Str(g.tm))
			}
			if g.opts.ResolveUse == nil {
				return fmt.Errorf("cannot resolve `use %q`: no resolver", usePath)
			}
			wuffsName := path.Base(usePath)
			id, err := g.tm.Insert(wuffsName)
			if err != nil {
				return err
			}
			if g.uses[id] != nil {
				return fmt.Errorf("duplicate `use %q`", usePath)
			}
			if !isValidAdaIdent(mangleGlobal(wuffsName)) {
				return fmt.Errorf("`use %q`: %q is not usable as an Ada identifier", usePath, wuffsName)
			}
			u := &usedPkg{
				id:      id,
				adaName: "Wuffs.Std." + mangleGlobal(wuffsName),
				structs: map[t.ID]*structInfo{},
			}
			g.uses[id] = u
			g.useList = append(g.useList, u)

			filename := usePath + ".wuffs"
			src, err := g.opts.ResolveUse(filename)
			if err != nil {
				return err
			}
			tokens, _, err := t.Tokenize(g.tm, filename, src)
			if err != nil {
				return err
			}
			f, err := parse.Parse(g.tm, filename, tokens, &parse.Options{AllowDoubleUnderscoreNames: true})
			if err != nil {
				return err
			}
			for _, o := range f.TopLevelDecls() {
				if o.Kind() != a.KStruct {
					continue
				}
				o := o.AsStruct()
				s := &structInfo{
					pkg:    u,
					classy: o.Classy(),
					ast:    o,
					name:   u.adaName + "." + mangleGlobal(o.QID()[1].Str(g.tm)),
				}
				s.typ = &adaType{kind: kStruct, name: s.name, st: s}
				u.structs[o.QID()[1]] = s
			}
			for _, o := range f.TopLevelDecls() {
				if o.Kind() != a.KFunc {
					continue
				}
				o := o.AsFunc()
				recv := u.structs[o.Receiver()[1]]
				if recv == nil {
					continue
				}
				fi := &funcInfo{ast: o, recv: recv}
				fi.sigErr = g.analyzeFunc(fi, u.adaName+".")
				g.funcs[t.QQID{id, o.Receiver()[1], o.FuncName()}] = fi
			}
		}
	}
	return nil
}

// usedPackages returns the Ada names of the generated packages that this one
// uses.
func (g *gen) usedPackages() []string {
	ret := []string(nil)
	for _, u := range g.useList {
		ret = append(ret, u.adaName)
	}
	return ret
}
