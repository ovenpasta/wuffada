#!/bin/sh
# Runs everything that has to pass for the YCbCr / YCCK part of the base
# library, apart from the proof:
#
#   1. the generators' checks: the checked-in generated Ada is exactly the
#      generators' output (the pixel library's two generators and this
#      part's gen_composite.py), and the compositing helpers generated here
#      (Wuffs.Base.Pixel_Composite) are character for character those in
#      the body of Wuffs.Base.Pixel_Rows, and the two set procedures of
#      Wuffs.Base.Pixel_Buffers.Rows have the per-format code of the pixel
#      library's checked setters (src/ycck/tools/check_rows.py);
#   2. in each profile (checked, release): build with warnings as errors,
#      bin/ycck_tests (oracle sweeps and explicit cases) and bin/ycck_fuzz
#      (the differential fuzz cases).
#
# Exit status 0 only if all of it passed.  Needs python3 and the wuffs
# checkout (for the generators); no C compiler.
#
# Usage: tests_ycck/run_all.sh   (from anywhere)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.."
python3 src/pixel/tools/gen_rows.py --check
python3 src/pixel/tools/gen_select.py --check
python3 src/ycck/tools/gen_composite.py --check
python3 src/ycck/tools/check_rows.py
echo "generators: checked-in files are their output; compositing helpers and row setters match the pixel library"
for profile in checked release; do
  alr exec -- gprbuild -q -P wuffs_ycck_tests.gpr -XWUFFS_PROFILE=$profile
  out=$(bin/ycck_tests) || { echo "$out"; echo "run_all: FAILED ($profile, ycck_tests)"; exit 1; }
  echo "$profile: $(echo "$out" | tail -1)"
  out=$(bin/ycck_fuzz < tests_ycck/fuzz/fuzz_cases.txt) || { echo "$out"; echo "run_all: FAILED ($profile, ycck_fuzz)"; exit 1; }
  echo "$profile: $(echo "$out" | tail -1)"
done
echo "run_all: passed"
