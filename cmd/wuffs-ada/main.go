// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// wuffs-ada generates Ada code from Wuffs code. It is the Ada counterpart of
// the Wuffs repository's cmd/wuffs-c.
//
// Usage:
//
//	wuffs-ada gen -package_name NAME [-o DIR] [flags] FILE.wuffs...
//	wuffs-ada genstd [-o DIR]
//
// The gen sub-command type- and bounds-checks the files of one Wuffs package
// (with the Wuffs compiler's own front end) and generates the Ada package
// Wuffs.Std.NAME. Given -o, it writes wuffs-std-NAME.ads and .adb in DIR.
// Otherwise it prints the spec and then the body to stdout (which gnatchop
// can split).
//
// The genstd sub-command generates the (empty) parent package Wuffs.Std.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/google/wuffs/lang/check"
	"github.com/google/wuffs/lang/parse"

	"wuffada/internal/adagen"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

func main() {
	if err := main1(); err != nil {
		os.Stderr.WriteString("wuffs-ada: " + err.Error() + "\n")
		os.Exit(1)
	}
}

func main1() error {
	if len(os.Args) < 2 {
		return fmt.Errorf("no sub-command given (want gen or genstd)")
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "gen":
		return doGen(args)
	case "genstd":
		return doGenStd(args)
	}
	return fmt.Errorf("bad sub-command %q (want gen or genstd)", os.Args[1])
}

func doGenStd(args []string) error {
	flags := flag.NewFlagSet("genstd", flag.ContinueOnError)
	outDir := flags.String("o", "", "the directory to write the Ada source file to (default: print to stdout)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("genstd takes no arguments")
	}
	if *outDir == "" {
		_, err := os.Stdout.WriteString(adagen.StdRootSpec)
		return err
	}
	return os.WriteFile(filepath.Join(*outDir, adagen.StdRootFile), []byte(adagen.StdRootSpec), 0644)
}

func doGen(args []string) error {
	flags := flag.NewFlagSet("gen", flag.ContinueOnError)
	packageName := flags.String("package_name", "", "the package name of the Wuffs input code")
	packageID := flags.Uint("package_id", 0,
		"overrides the package's status-code namespace, 1 ..= 65535 (default: from internal/adagen/package_ids.txt)")
	wuffsRoot := flags.String("wuffsroot", "wuffs",
		"the root directory of the Wuffs repository: `use \"std/foo\"` refers to the sources in its std/foo directory")
	outDir := flags.String("o", "", "the directory to write the Ada source files to (default: print to stdout)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *packageName == "" {
		return fmt.Errorf("gen: missing -package_name")
	}
	if flags.NArg() == 0 {
		return fmt.Errorf("gen: no input files")
	}
	if *packageID > 0xFFFF {
		return fmt.Errorf("gen: -package_id out of range")
	}

	if *packageID == 0 {
		id, err := adagen.PackageID(*packageName)
		if err != nil {
			return err
		}
		*packageID = uint(id)
	}

	tm := &t.Map{}
	files := []*a.File(nil)
	for _, filename := range flags.Args() {
		src, err := os.ReadFile(filename)
		if err != nil {
			return err
		}
		// Record the name as given, with forward slashes, so that the
		// output does not depend on the host OS.
		name := filepath.ToSlash(filename)
		tokens, _, err := t.Tokenize(tm, name, src)
		if err != nil {
			return err
		}
		f, err := parse.Parse(tm, name, tokens, nil)
		if err != nil {
			return err
		}
		files = append(files, f)
	}

	// A "use" declaration is resolved from the used package's sources
	// under the Wuffs root, not from the gen/wuffs interface files that
	// upstream's "wuffs gen" writes: see adagen.UseResolver.
	resolveUse := adagen.UseResolver(*wuffsRoot)
	if _, err := check.Check(tm, files, resolveUse); err != nil {
		return err
	}

	out, err := adagen.Generate(tm, files, adagen.Options{
		PackageName: *packageName,
		PackageID:   uint32(*packageID),
		ResolveUse:  resolveUse,
	})
	if err != nil {
		return err
	}

	if *outDir == "" {
		if _, err := os.Stdout.Write(out.Spec); err != nil {
			return err
		}
		_, err := os.Stdout.Write(append([]byte("\n"), out.Body...))
		return err
	}
	if err := os.WriteFile(filepath.Join(*outDir, out.SpecFile), out.Spec, 0644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(*outDir, out.BodyFile), out.Body, 0644)
}
