#!/bin/sh
# A mutation check for the token library's tests (ada/tests_token): it
# applies one deliberate fault at a time to a scratch copy of ada/src/token
# and reports, for each profile, whether bin/token_tests notices.  In the
# release profile (no run-time checks) a fault counts as killed only if a
# check fails (a digest from upstream's C or an explicit case), not if the
# program raises an exception.
#
# usage: ada/tests_token/mutation.sh SCRATCH_DIR
#
# SCRATCH_DIR must not exist; it is left in place, with a log per mutant
# and profile (remove it afterwards).  Nothing in this tree is changed.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 SCRATCH_DIR" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
ada="$(cd "$here/.." && pwd)"
scratch="$1"
[ ! -e "$scratch" ] || { echo "$scratch exists" >&2; exit 2; }
mkdir -p "$scratch"
scratch="$(cd "$scratch" && pwd)"
copy="$scratch/ada"
mkdir "$copy" "$copy/src"
cp -r "$ada/src/root" "$ada/src/base" "$ada/src/token" "$copy/src/"
cp -r "$ada/tests_token" "$copy/"
cp "$ada/wuffs_common.gpr" "$ada/gnat.adc" "$ada/wuffs_token_tests.gpr" "$ada/alire.toml" "$copy/"
cp -r "$ada/alire" "$copy/" 2>/dev/null || true
cp -r "$copy/src/token" "$scratch/token.orig"

T=src/token/wuffs-base-tokens
U=src/token/wuffs-base-utf8

# NAME FILE OLD NEW: one mutant (OLD must occur exactly once in FILE).
#
# A06 is an equivalent mutant, kept as a record: "<=" and "<" differ only
# when U64 (Old_Ri) = History_Retain_Length, and then both branches of the
# if-expression give Old_Ri.  A17 is the non-equivalent fault next to it.
mutants() {
cat <<'LIST'
A01-major-shift|T.ads|Value_Major_Shift         : constant := 42;|Value_Major_Shift         : constant := 41;
A02-continued-shift|T.ads|Continued_Shift           : constant := 16;|Continued_Shift           : constant := 15;
A03-extension-not-complemented|T.ads|(Shift_Right_Signed (not T, Value_Extension_Shift));|(Shift_Right_Signed (T, Value_Extension_Shift));
A04-base-detail-mask|T.ads|(Interfaces.Shift_Right (T, Value_Base_Detail_Shift) and 16#1F_FFFF#);|(Interfaces.Shift_Right (T, Value_Base_Detail_Shift) and 16#F_FFFF#);
A05-closed-buffer-writable|T.ads|(Iop => M.Wi, Io2 => (if M.Closed then M.Wi else Data_Length))|(Iop => M.Wi, Io2 => Data_Length)
A06-retain-one-less|T.adb|(if U64 (Old_Ri) <= History_Retain_Length|(if U64 (Old_Ri) < History_Retain_Length
A07-utf8-3-byte-overlong-boundary|U.adb|if C <= 16#07FF# or else (16#D800# <= C and then C <= 16#DFFF#) then|if C < 16#07FF# or else (16#D800# <= C and then C <= 16#DFFF#) then
A08-utf8-surrogate-upper-bound|U.adb|if C <= 16#07FF# or else (16#D800# <= C and then C <= 16#DFFF#) then|if C <= 16#07FF# or else (16#D800# <= C and then C <= 16#DFFE#) then
A09-next-from-end-looks-back-3|U.adb|Max_N : constant U32 := (if Len > 4 then 4 else U32 (Len));|Max_N : constant U32 := (if Len > 3 then 3 else U32 (Len));
A10-prefix-stops-at-7f|U.adb|if O.Code_Point > 16#7F# and then O.Byte_Length = 1 then|if O.Code_Point >= 16#7F# and then O.Byte_Length = 1 then
A11-encode-2-byte-boundary|U.adb|elsif Code_Point <= 16#07FF# then|elsif Code_Point <= 16#0800# then
A12-valid-length-ignores-up-to|U.adb|if U64 (Avail) <= Up_To then|if True then
A13-save-stores-io2|T.adb|M := (M with delta Wi => W.Iop);|M := (M with delta Wi => W.Io2);
A14-table-c1-is-a-lead-byte|U.ads|when 16#C0# .. 16#C1# => 16#80#,|when 16#C0# .. 16#C1# => 1,
A15-encode-4-byte-tail-mask|U.adb|Dst (F + 3) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 0) and 16#3F#));|Dst (F + 3) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 0) and 16#1F#));
A17-retain-one-more|T.adb|then Old_Ri else Index (History_Retain_Length));|then Old_Ri else Index (History_Retain_Length) + 1);
A16-sign-extend-shift|T.ads|(Shift_Right_Signed (Interfaces.Shift_Left (T, 43 - Value_Base_Detail_Shift), 43));|(Shift_Right_Signed (Interfaces.Shift_Left (T, 42 - Value_Base_Detail_Shift), 42));
LIST
}

run_one() {
    name="$1"; profile="$2"
    log="$scratch/$name.$profile.log"
    if ! (cd "$copy" && alr exec -- gprbuild -q -P wuffs_token_tests.gpr -XWUFFS_PROFILE="$profile") > "$log" 2>&1; then
        echo "$name ($profile): killed by the build"; return
    fi
    if (cd "$copy" && timeout 600 bin/token_tests) >> "$log" 2>&1; then
        echo "$name ($profile): SURVIVED"
    elif grep -q '^FAIL: ' "$log"; then
        echo "$name ($profile): killed by: $(grep '^FAIL: ' "$log" | sed 's/^FAIL: //' | head -n 4 | tr '\n' ',' | sed 's/,$//')"
    elif [ "$profile" = release ]; then
        echo "$name ($profile): NOT KILLED BY A CHECK (the program failed otherwise: see $log)"
    else
        echo "$name ($profile): killed by a run-time check: $(grep -m1 -i 'raised\|error' "$log" || true)"
    fi
}

for profile in checked release; do
    run_one 00-unchanged "$profile"
done
mutants | while IFS='|' read -r name file old new; do
    case "$file" in
        T.ads) path="$copy/$T.ads" ;;
        T.adb) path="$copy/$T.adb" ;;
        U.ads) path="$copy/$U.ads" ;;
        U.adb) path="$copy/$U.adb" ;;
    esac
    rm -rf "$copy/src/token"; cp -r "$scratch/token.orig" "$copy/src/token"
    if ! python3 - "$path" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
    then
        echo "$name: INVALID (the text to replace was not found exactly once)"
        continue
    fi
    for profile in checked release; do
        run_one "$name" "$profile"
    done
done
rm -rf "$copy/src/token"; cp -r "$scratch/token.orig" "$copy/src/token"
echo "done"
