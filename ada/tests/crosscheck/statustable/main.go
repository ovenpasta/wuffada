// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// statustable prints how the Ada status values correspond to upstream C's
// status strings, for ada/tests/crosscheck/decode.c: one line
// "CATEGORY CODE STRING" per status, where CATEGORY is the position of the
// Wuffs.Status_Category (Ok = 0, Note = 1, Suspension = 2, Error = 3), CODE
// is the Wuffs.Status_Code in decimal and STRING is the C string, such as
// "#deflate: bad block".
//
// It reads them from the Ada sources, where the generator (and, for the base
// package, the base library's author) recorded each status' Wuffs message
// next to its constant:
//
//	statustable ada/src/base/wuffs-base.ads ada/gen/wuffs-std-*.ads
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

var (
	// wuffs-base.ads:
	//    Note_IO_Redirect : constant Status :=
	//      (Category => Note, Code => 1);
	//    --  "base: I/O redirect"
	baseValueRE   = regexp.MustCompile(`^\s*\(Category => (\w+), Code => (\d+)\);`)
	baseMessageRE = regexp.MustCompile(`^\s*--  "(base: .*)"$`)

	// wuffs-std-*.ads:
	//    --  Wuffs: status "#bad code"
	//    Error_Bad_Code : constant Wuffs.Status := (Error, 16#0003_0001#);
	genMessageRE = regexp.MustCompile(`^\s*--  Wuffs: status "(.*)"$`)
	genValueRE   = regexp.MustCompile(`\((Note|Suspension|Error), 16#([0-9A-F_]+)#\);`)
	genPackageRE = regexp.MustCompile(`^package Wuffs\.Std\.(\w+)`)
)

var categories = map[string]int{"Ok": 0, "Note": 1, "Suspension": 2, "Error": 3}

var sigils = map[string]string{"Note": "@", "Suspension": "$", "Error": "#"}

func main() {
	for _, name := range os.Args[1:] {
		f, err := os.Open(name)
		if err != nil {
			fmt.Fprintln(os.Stderr, "statustable:", err)
			os.Exit(1)
		}
		pkg, category, code, message := "", "", "", ""
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if m := genPackageRE.FindStringSubmatch(line); m != nil {
				pkg = strings.ToLower(m[1])
			} else if m := baseValueRE.FindStringSubmatch(line); m != nil {
				category, code = m[1], m[2]
			} else if m := baseMessageRE.FindStringSubmatch(line); m != nil && category != "" {
				fmt.Printf("%d %s %s%s\n", categories[category], code, sigils[category], m[1])
				category = ""
			} else if m := genMessageRE.FindStringSubmatch(line); m != nil {
				message = m[1]
			} else if m := genValueRE.FindStringSubmatch(line); m != nil && message != "" {
				n, err := strconv.ParseUint(strings.ReplaceAll(m[2], "_", ""), 16, 32)
				if err != nil || pkg == "" {
					fmt.Fprintf(os.Stderr, "statustable: %s: cannot parse %q\n", name, line)
					os.Exit(1)
				}
				// C: the sigil, the package name, ": " and the message.
				fmt.Printf("%d %d %s%s: %s\n", categories[m[1]], n, message[:1], pkg, message[1:])
				message = ""
			}
		}
		f.Close()
	}
}
