// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// hashexpect prints, for each file named on the command line, a line
// "ADLER32 CRC32 PATH" (both checksums as 8 hexadecimal digits) computed with
// Go's standard library. It is the independent implementation that
// ada/tests/test_hashers.adb checks the generated Ada hashers against: pipe
// its output to that program's standard input.
package main

import (
	"fmt"
	"hash/adler32"
	"hash/crc32"
	"os"
)

func main() {
	for _, name := range os.Args[1:] {
		data, err := os.ReadFile(name)
		if err != nil {
			fmt.Fprintln(os.Stderr, "hashexpect:", err)
			os.Exit(1)
		}
		fmt.Printf("%08X %08X %s\n", adler32.Checksum(data), crc32.ChecksumIEEE(data), name)
	}
}
