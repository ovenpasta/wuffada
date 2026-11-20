// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// pnmcheck compares what examples/decode_image wrote with what Go's
// image/png or image/gif decodes from the same input.
//
// Usage: pnmcheck INPUT OUTPUT
//
// INPUT is a PNG or GIF file and OUTPUT is the PPM (P6) or PAM (P7,
// RGB_ALPHA) file that decode_image made from it. For a GIF, the first frame
// is compared, within its bounds. Fully transparent pixels are equal
// whatever their colour.
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"io"
	"log"
	"os"
)

func main() {
	log.SetFlags(0)
	if len(os.Args) != 3 {
		log.Fatal("usage: pnmcheck INPUT OUTPUT")
	}
	in, err := os.ReadFile(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	var m image.Image
	var bounds image.Rectangle
	if bytes.HasPrefix(in, []byte("GIF")) {
		g, err := gif.DecodeAll(bytes.NewReader(in))
		if err != nil {
			log.Fatal(err)
		}
		m, bounds = g.Image[0], g.Image[0].Bounds()
	} else {
		if m, err = png.Decode(bytes.NewReader(in)); err != nil {
			log.Fatal(err)
		}
		bounds = m.Bounds()
	}

	f, err := os.Open(os.Args[2])
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	r := bufio.NewReader(f)
	var magic string
	var w, h, channels int
	fmt.Fscan(r, &magic)
	switch magic {
	case "P6":
		var maxval int
		fmt.Fscan(r, &w, &h, &maxval)
		r.ReadByte()
		channels = 3
	case "P7":
		var key string
		for key != "ENDHDR" {
			if _, err := fmt.Fscan(r, &key); err != nil {
				log.Fatal("pnmcheck: bad PAM header")
			}
			switch key {
			case "WIDTH":
				fmt.Fscan(r, &w)
			case "HEIGHT":
				fmt.Fscan(r, &h)
			}
		}
		r.ReadByte()
		channels = 4
	default:
		log.Fatalf("pnmcheck: unexpected magic %q", magic)
	}
	pix := make([]byte, w*h*channels)
	if _, err := io.ReadFull(r, pix); err != nil {
		log.Fatalf("pnmcheck: short pixel data: %v", err)
	}
	if _, err := r.ReadByte(); err != io.EOF {
		log.Fatal("pnmcheck: trailing data")
	}
	if !bounds.In(image.Rect(0, 0, w, h)) {
		log.Fatalf("pnmcheck: the output is %d by %d but the reference has bounds %v", w, h, bounds)
	}

	bad := 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			want := color.NRGBAModel.Convert(m.At(x, y)).(color.NRGBA)
			p := pix[(y*w+x)*channels:]
			got := color.NRGBA{p[0], p[1], p[2], 0xFF}
			if channels == 4 {
				got.A = p[3]
			}
			if got != want && (got.A != 0 || want.A != 0) {
				bad++
			}
		}
	}
	if bad != 0 {
		log.Fatalf("pnmcheck: %d pixels differ", bad)
	}
	fmt.Printf("pnmcheck: %s: %d by %d, %d channels: same pixels as Go's decoder\n", os.Args[1], w, h, channels)
}
