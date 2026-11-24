#!/bin/sh
# A mutation check of the destination offset (dst_x_offset, dst_y_offset)
# code of Wuffs.Base.Pixel_Swizzler_YCCK: it applies one deliberate fault at
# a time to a scratch copy of ada/ and reports whether bin/ycck_tests (the
# oracle sweeps and the explicit cases) notices, in each profile.
#
# usage: tests_ycck/mutation.sh SCRATCH_DIR   (from anywhere)
#
# SCRATCH_DIR must not exist; it is left in place, with a log per mutant and
# profile (remove it afterwards).  Nothing in this tree is changed.  Exit
# status 0 only if every mutant was noticed in both profiles.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 SCRATCH_DIR" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
scratch=$1
[ ! -e "$scratch" ] || { echo "$scratch exists" >&2; exit 2; }
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd)
copy="$scratch/ada"
mkdir "$copy"
(cd "$root" && tar cf - --exclude=./obj --exclude=./bin --exclude=./lib --exclude=./prove .) |
    (cd "$copy" && tar xf -)
body=src/ycck/wuffs-base-pixel_swizzler_ycck.adb

# NAME|OLD|NEW: the first (and only) occurrence of OLD in the body becomes
# NEW.  "@" stands for a newline.
mutants='
O01-x-offset-not-applied|IX     => U64 (DX) * U64 (B),|IX     => 0,
O02-y-offset-not-applied|IY     => U64 (DY),|IY     => 0,
O03-y-offset-taken-from-x|IY     => U64 (DY),|IY     => U64 (DX),
O04-view-width-not-reduced|View.Pixcfg.Width := PB.Pixcfg.Width - DX;|View.Pixcfg.Width := PB.Pixcfg.Width - DX / 2;
O05-view-height-not-reduced|View.Pixcfg.Height := PB.Pixcfg.Height - DY;|View.Pixcfg.Height := PB.Pixcfg.Height - DY / 2;
O06-x-offset-outside-not-a-no-op|if DX >= PB.Pixcfg.Width or else DY >= PB.Pixcfg.Height then|if DY >= PB.Pixcfg.Height then
O07-y-offset-outside-not-a-no-op|if DX >= PB.Pixcfg.Width or else DY >= PB.Pixcfg.Height then|if DX >= PB.Pixcfg.Width then
O08-view-only-for-an-x-offset|if (Dst_X_Offset /= 0 or else Dst_Y_Offset /= 0)|if (Dst_X_Offset /= 0)
O09-view-not-used|(PB                => View,|(PB                => PB,
O10-view-plane-0-unchanged|Result => View.Planes (0));|Result => View.Planes (1));
'
echo "$mutants" | while IFS='|' read -r name old new; do
    [ -n "$name" ] || continue
    for profile in checked release; do
        (cd "$root" && cat "$body") > "$copy/$body"
        python3 - "$copy/$body" "$old" "$new" <<'EOF'
import sys
path, old, new = sys.argv[1], sys.argv[2].replace("@", "\n"), sys.argv[3].replace("@", "\n")
s = open(path).read()
if s.count(old) != 1:
    sys.exit("mutation.sh: %d occurrences of %r" % (s.count(old), old))
open(path, "w").write(s.replace(old, new))
EOF
        log="$scratch/$name.$profile.log"
        if ! (cd "$copy" && alr exec -- gprbuild -q -P wuffs_ycck_tests.gpr -XWUFFS_PROFILE=$profile) > "$log" 2>&1; then
            echo "$name ($profile): KILLED (does not build)"
            continue
        fi
        if (cd "$copy" && timeout 600 bin/ycck_tests) >> "$log" 2>&1; then
            echo "$name ($profile): SURVIVED"
            echo survived >> "$scratch/survivors"
        else
            echo "$name ($profile): KILLED ($(grep -c 'FAIL' "$log" || true) failed checks)"
        fi
    done
done
(cd "$root" && cat "$body") > "$copy/$body"
if [ -e "$scratch/survivors" ]; then
    echo "mutation.sh: $(wc -l < "$scratch/survivors" | tr -d ' ') survivors"
    exit 1
fi
echo "mutation.sh: every mutant was killed in both profiles"
