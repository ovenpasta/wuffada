// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// hashexpect2 prints, for each file named on the command line, a line
// "XXHASH32 XXHASH64 CRC64 SHA256 PATH" (8, 16, 16 and 64 hexadecimal digits):
// CRC-64/ECMA from Go's hash/crc64, SHA-256 from crypto/sha256 and the two xxHash checksums (seed 0) from the
// implementations in this file, written from the algorithm's description.
// It is the independent implementation that ada/tests/test_hashers2.adb
// checks the generated Ada hashers against; test.sh also compares its output
// with what upstream's C hashers compute (ada/tests/crosscheck/hash2.c).
package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"hash/crc64"
	"math/bits"
	"os"
)

func xxhash32(b []byte) uint32 {
	const p1, p2, p3, p4, p5 = 2654435761, 2246822519, 3266489917, 668265263, 374761393
	n := len(b)
	h := uint32(p5)
	if n >= 16 {
		v := [4]uint32{p1, p2, 0, 0}
		v[0] += p2
		v[3] -= p1
		for ; len(b) >= 16; b = b[16:] {
			for i := range v {
				v[i] = bits.RotateLeft32(v[i]+binary.LittleEndian.Uint32(b[4*i:])*p2, 13) * p1
			}
		}
		h = bits.RotateLeft32(v[0], 1) + bits.RotateLeft32(v[1], 7) + bits.RotateLeft32(v[2], 12) +
			bits.RotateLeft32(v[3], 18)
	}
	h += uint32(n)
	for ; len(b) >= 4; b = b[4:] {
		h = bits.RotateLeft32(h+binary.LittleEndian.Uint32(b)*p3, 17) * p4
	}
	for _, c := range b {
		h = bits.RotateLeft32(h+uint32(c)*p5, 11) * p1
	}
	h ^= h >> 15
	h *= p2
	h ^= h >> 13
	h *= p3
	h ^= h >> 16
	return h
}

func xxhash64(b []byte) uint64 {
	const (
		p1 = 11400714785074694791
		p2 = 14029467366897019727
		p3 = 1609587929392839161
		p4 = 9650029242287828579
		p5 = 2870177450012600261
	)
	round := func(acc, in uint64) uint64 { return bits.RotateLeft64(acc+in*p2, 31) * p1 }
	n := len(b)
	h := uint64(p5)
	if n >= 32 {
		v := [4]uint64{p1, p2, 0, 0}
		v[0] += p2
		v[3] -= p1
		for ; len(b) >= 32; b = b[32:] {
			for i := range v {
				v[i] = round(v[i], binary.LittleEndian.Uint64(b[8*i:]))
			}
		}
		h = bits.RotateLeft64(v[0], 1) + bits.RotateLeft64(v[1], 7) + bits.RotateLeft64(v[2], 12) +
			bits.RotateLeft64(v[3], 18)
		for _, x := range v {
			h = (h^round(0, x))*p1 + p4
		}
	}
	h += uint64(n)
	for ; len(b) >= 8; b = b[8:] {
		h = bits.RotateLeft64(h^round(0, binary.LittleEndian.Uint64(b)), 27)*p1 + p4
	}
	if len(b) >= 4 {
		h = bits.RotateLeft64(h^uint64(binary.LittleEndian.Uint32(b))*p1, 23)*p2 + p3
		b = b[4:]
	}
	for _, c := range b {
		h = bits.RotateLeft64(h^uint64(c)*p5, 11) * p1
	}
	h ^= h >> 33
	h *= p2
	h ^= h >> 29
	h *= p3
	h ^= h >> 32
	return h
}

func main() {
	table := crc64.MakeTable(crc64.ECMA)
	for _, name := range os.Args[1:] {
		data, err := os.ReadFile(name)
		if err != nil {
			fmt.Fprintln(os.Stderr, "hashexpect2:", err)
			os.Exit(1)
		}
		fmt.Printf("%08X %016X %016X %X %s\n", xxhash32(data), xxhash64(data), crc64.Checksum(data, table),
			sha256.Sum256(data), name)
	}
}
