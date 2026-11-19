// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	_ "embed"
	"fmt"
	"strconv"
	"strings"
)

//go:embed package_ids.txt
var packageIDsText string

// PackageID returns the status-code namespace that package_ids.txt assigns
// to the Wuffs package called name, or zero if it assigns none.
func PackageID(name string) (uint32, error) {
	seen := map[uint64]string{}
	ret := uint32(0)
	for i, line := range strings.Split(packageIDsText, "\n") {
		if j := strings.IndexByte(line, '#'); j >= 0 {
			line = line[:j]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		id, err := strconv.ParseUint(fields[len(fields)-1], 10, 32)
		if len(fields) != 2 || err != nil || id == 0 || id > 0xFFFF {
			return 0, fmt.Errorf("package_ids.txt:%d: malformed line", i+1)
		}
		if prev, ok := seen[id]; ok {
			return 0, fmt.Errorf("package_ids.txt:%d: id %d is already assigned to %s", i+1, id, prev)
		}
		seen[id] = fields[0]
		if fields[0] == name {
			if ret != 0 {
				return 0, fmt.Errorf("package_ids.txt:%d: package %s is listed twice", i+1, name)
			}
			ret = uint32(id)
		}
	}
	return ret, nil
}
