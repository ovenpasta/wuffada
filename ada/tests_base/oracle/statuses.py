# Prints, as Ada, the base status strings found in the Wuffs release C file,
# in file order:
#  - Statuses: the sigil ('@' note, '$' suspension, '#' error) and the
#    message without it, padded to a common length;
#  - Named: for each, the Wuffs.Base constant that should denote it, with
#    the constant's name derived from the upstream text by rule, not copied
#    from wuffs-base.ads.  If wuffs-base.ads lacks one of these names the
#    tests do not compile; if a name is attached to the wrong status the
#    tests fail (test_status.adb compares Named (I) with Statuses (I)).
#
# Naming rule: Note_ / Suspension_ / Error_ + the message after "base: ",
# each run of non-alphanumeric characters becoming one underscore and each
# word capitalised.  EXCEPTIONS lists the constants whose name in
# wuffs-base.ads departs from the rule, keyed by the rule's name.
import re
import sys

EXCEPTIONS = {
    "Note_I_O_Redirect": "Note_IO_Redirect",
    "Error_Bad_I_O_Position": "Error_Bad_IO_Position",
    "Error_Disabled_By_WUFFS_CONFIG_DST_PIXEL_FORMAT_ENABLE_ALLOWLIST":
        "Error_Disabled_By_Dst_Pixel_Format_Enable_Allowlist",
}
PREFIX = {"@": "Note_", "$": "Suspension_", "#": "Error_"}


def rule_name(s):
    msg = s[1:]
    assert msg.startswith("base: "), s
    words = [w for w in re.split(r"[^A-Za-z0-9]+", msg[len("base: "):]) if w]
    return PREFIX[s[0]] + "_".join(w[0].upper() + w[1:] for w in words)


text = open(sys.argv[1], encoding="utf-8").read()
found = re.findall(
    r'^const char wuffs_base__(?:note|suspension|error)__\w+\[\] = "(.*)";$',
    text, re.M)
if not found:
    sys.exit("no base statuses found")
width = max(len(s) - 1 for s in found)
print("   Num_Statuses : constant := %d;" % len(found))
print("   Message_Width : constant := %d;" % width)
print()
print("   type Status_Entry is record")
print("      Sigil  : Character;")
print("      Length : Natural;")
print("      Text   : String (1 .. Message_Width);")
print("   end record;")
print()
print("   Statuses : constant array (1 .. Num_Statuses) of Status_Entry :=")
print("     [")
for i, s in enumerate(found):
    assert '"' not in s and "\\" not in s, s
    sep = "," if i + 1 < len(found) else ""
    print("      ('%s', %d," % (s[0], len(s) - 1))
    print('       "%s")%s' % (s[1:].ljust(width), sep))
print("     ];")
print()
print("   --  Names derived from the texts above by the rule in")
print("   --  oracle/statuses.py; a comment marks each exception to the rule.")
print("   Named : constant array (1 .. Num_Statuses) of Wuffs.Status :=")
print("     [")
used = set()
for i, s in enumerate(found):
    sep = "," if i + 1 < len(found) else ""
    rule = rule_name(s)
    name = EXCEPTIONS.get(rule, rule)
    if rule in EXCEPTIONS:
        used.add(rule)
        print("      --  by rule: %s" % rule)
    print("      Wuffs.Base.%s%s" % (name, sep))
print("     ];")
assert used == set(EXCEPTIONS), set(EXCEPTIONS) - used
