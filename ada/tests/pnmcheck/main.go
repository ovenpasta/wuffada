// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// pnmcheck compares what examples/decode_image wrote with what Go's
// image/png, image/gif or image/jpeg decodes from the same input.
//
// Usage: pnmcheck INPUT OUTPUT
//
// INPUT is a PNG, GIF or JPEG file and OUTPUT is the PPM (P6) or PAM (P7,
// RGB_ALPHA) file that decode_image made from it. For a GIF, the first frame
// is compared, within its bounds. Fully transparent pixels are equal
// whatever their colour. A JPEG's pixels are compared with a tolerance, as
// ada/tests/imgcorpus does (see jpegCategory there): 2 per channel for a
// grayscale image, 4 for colour without chroma subsampling, and 96 with it
// (Wuffs' default triangle upsampling against Go's box filter).
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
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
	tolerance := 0
	if bytes.HasPrefix(in, []byte{0xFF, 0xD8}) {
		if m, err = jpeg.Decode(bytes.NewReader(in)); err != nil {
			log.Fatal(err)
		}
		bounds = m.Bounds()
		tolerance = 4
		switch m := m.(type) {
		case *image.Gray:
			tolerance = 2
		case *image.YCbCr:
			if m.SubsampleRatio != image.YCbCrSubsampleRatio444 {
				tolerance = 96
			}
		}
	} else if bytes.HasPrefix(in, []byte("GIF")) {
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

	bad, largest := 0, 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			want := color.NRGBAModel.Convert(m.At(x, y)).(color.NRGBA)
			if c, ok := m.(*image.YCbCr); ok {
				// The 8-bit conversion, not the 16-bit one of At's RGBA.
				yy := c.YCbCrAt(x, y)
				r, g, b := color.YCbCrToRGB(yy.Y, yy.Cb, yy.Cr)
				want = color.NRGBA{r, g, b, 0xFF}
			}
			p := pix[(y*w+x)*channels:]
			got := color.NRGBA{p[0], p[1], p[2], 0xFF}
			if channels == 4 {
				got.A = p[3]
			}
			if got.A == 0 && want.A == 0 {
				continue
			}
			d := 0
			for i, v := range []uint8{got.R, got.G, got.B, got.A} {
				u := []uint8{want.R, want.G, want.B, want.A}[i]
				if v > u && int(v-u) > d {
					d = int(v - u)
				} else if u > v && int(u-v) > d {
					d = int(u - v)
				}
			}
			if d > largest {
				largest = d
			}
			if d > tolerance {
				bad++
			}
		}
	}
	if bad != 0 {
		log.Fatalf("pnmcheck: %d pixels differ by more than %d", bad, tolerance)
	}
	if tolerance == 0 {
		fmt.Printf("pnmcheck: %s: %d by %d, %d channels: same pixels as Go's decoder\n", os.Args[1], w, h, channels)
	} else {
		fmt.Printf("pnmcheck: %s: %d by %d, %d channels: within %d of Go's decoder (at most %d apart)\n",
			os.Args[1], w, h, channels, tolerance, largest)
	}
}
