#!/usr/bin/env python3
# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Checks, with objdump, which functions of a linked program hold
instructions beyond the x86-64 baseline (SSE2): SSE3, SSSE3, SSE4.1/4.2,
POPCNT, PCLMULQDQ, AVX/AVX2 (any VEX-encoded instruction), BMI1/BMI2, LZCNT,
MOVBE, FMA, AES, SHA.

Only the SIMD units may hold them: the generated private children
Wuffs.Std.<pkg>.X86_<feature> (symbols wuffs__std__<pkg>__x86_<feature>__*),
the runtime Wuffs.Runtime.X86.* (wuffs__runtime__x86__*), and the test unit
X86_Test_Cases (x86_test_cases__*). Anything else that holds one is reported
and the exit status is 1: the library must run on any x86-64 CPU until a
choose statement has asked the CPU.

With --expect UNIT=MNEMONIC_PREFIX[,PREFIX...] (repeatable), it also checks
that some function of the unit (symbol prefix) holds an instruction whose
mnemonic starts with one of the prefixes: that the SIMD units were really
compiled with their -m options.

Usage: isacheck.py [--expect UNIT=PREFIXES]... PROGRAM...
"""
import re
import subprocess
import sys

BEYOND = set('''
addsubpd addsubps haddpd haddps hsubpd hsubps lddqu movddup movshdup movsldup fisttp
pabsb pabsw pabsd palignr phaddw phaddd phaddsw phsubw phsubd phsubsw pmaddubsw pmulhrsw pshufb
psignb psignw psignd
blendpd blendps blendvpd blendvps dppd dpps extractps insertps movntdqa mpsadbw packusdw pblendvb
pblendw pcmpeqq pextrb pextrd pextrq phminposuw pinsrb pinsrd pinsrq pmaxsb pmaxsd pmaxud pmaxuw
pminsb pminsd pminud pminuw pmovsxbw pmovsxbd pmovsxbq pmovsxwd pmovsxwq pmovsxdq pmovzxbw pmovzxbd
pmovzxbq pmovzxwd pmovzxwq pmovzxdq pmuldq pmulld ptest roundpd roundps roundsd roundss
crc32 crc32b crc32w crc32l crc32q pcmpestri pcmpestrm pcmpgtq pcmpistri pcmpistrm
popcnt lzcnt andn bextr blsi blsmsk blsr bzhi mulx pdep pext rorx sarx shlx shrx movbe adcx adox
'''.split())
PREFIXES = ('pclmul', 'aes', 'sha1', 'sha256')
# Not "tzcnt": GCC emits it for the x86-64 baseline as "rep bsf", which a
# CPU without BMI1 runs as BSF, with the same result where GCC uses it
# (objdump shows the encoding as tzcnt; std/bmp's process_masks has one).
# VEX/EVEX instructions all start with 'v'; these baseline ones do too.
V_BASELINE = {'verr', 'verw'}

ALLOWED = re.compile(r'^(wuffs__std__[a-z0-9_]+?__x86_(sse42|avx2|bmi2)__|wuffs__runtime__x86__|x86_test_cases__)')


def beyond(mnemonic):
    m = mnemonic.split(',')[0]
    if m in BEYOND or m.startswith(PREFIXES):
        return True
    return m.startswith('v') and m not in V_BASELINE


def scan(path):
    out = subprocess.run(['objdump', '-d', '--no-show-raw-insn', path], capture_output=True, text=True,
                         check=True).stdout
    funcs = {}
    cur = None
    for line in out.splitlines():
        h = re.match(r'^[0-9a-f]+ <(.+)>:$', line)
        if h:
            cur = h.group(1)
            continue
        i = re.match(r'^\s+[0-9a-f]+:\s+(\S+)', line)
        if i and cur is not None:
            words = line.split('\t')
            text = words[-1].strip() if len(words) > 1 else ''
            parts = text.split()
            while parts and parts[0] in ('rep', 'repz', 'repe', 'repnz', 'repne', 'lock', 'notrack', 'bnd',
                                         'data16', 'cs', 'ds', 'es', 'fs', 'gs', 'ss'):
                parts = parts[1:]
            if parts and beyond(parts[0]):
                funcs.setdefault(cur, set()).add(parts[0])
    return funcs


def main():
    args = sys.argv[1:]
    expects = []
    while args and args[0] == '--expect':
        unit, prefixes = args[1].split('=')
        expects.append((unit, tuple(prefixes.split(','))))
        args = args[2:]
    bad = 0
    for path in args:
        funcs = scan(path)
        allowed = {f: s for f, s in funcs.items() if ALLOWED.match(f)}
        others = {f: s for f, s in funcs.items() if not ALLOWED.match(f)}
        for f, s in sorted(others.items()):
            print('isacheck: %s: %s: %s' % (path, f, ' '.join(sorted(s))))
            bad += 1
        n = sum(len(s) for s in allowed.values())
        print('isacheck: %s: %d functions of SIMD units hold instructions beyond x86-64 (%d distinct '
              'mnemonics); %d other functions do' % (path, len(allowed), len(set().union(*allowed.values()))
                                                    if allowed else 0, len(others)))
        for unit, prefixes in expects:
            hit = [f for f, s in allowed.items() if f.startswith(unit) and any(m.startswith(prefixes) for m in s)]
            if not hit:
                print('isacheck: %s: no function of %s holds %s' % (path, unit, '/'.join(prefixes)))
                bad += 1
    sys.exit(1 if bad else 0)


main()
