# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# The one table of the wrappers in Wuffs.Runtime.X86.SSE42 and AVX2 (every
# Wuffs x86 cpu_arch method that the generator can emit), and what is
# generated from it:
#
#   ../x86_methods.ads       the Method enumeration and the immediates tested
#   ../x86_methods.list      the Wuffs method of each entry ("type.method"),
#                            which internal/adagen's TestX86MethodTable
#                            compares with the generator's own table
#   ../x86_test_cases.adb    the Ada calls of the wrappers
#   x86_oracle.c             the same calls of upstream's _mm_* intrinsics
#                            (the ones wuffs/internal/cgen/builtin.go maps
#                            each method to), printing checkpointed digests
#
# Run by regen.sh. Usage: python3 gen.py
import os

here = os.path.dirname(os.path.abspath(__file__))
up = os.path.join(here, '..')

V128, V256 = 'v128', 'v256'
S = 'Wuffs.Runtime.X86.SSE42.'
X = 'Wuffs.Runtime.X86.AVX2.'
SH32 = [0, 1, 5, 15, 16, 31, 32, 33, 63, 64, 127, 128, 255]
SHUF = [0x00, 0x1B, 0x4E, 0xB1, 0xE4, 0xFF, 0x55, 0xAA, 0x93, 0x39, 0xD8, 0x72, 0x80, 0x01]

# Each entry: (Ada enumeration literal, Wuffs "type.method", Ada call, C expression,
# result kind, immediates or None, operand width).
# In the calls: {A} {B} {C} are the operands (vectors, or for make_* the
# Bytes32 whose lanes are the scalar arguments), {I} the immediate, {N} the
# input number (for loads and the store: the offset is N mod 64, or N mod 32
# u16 elements). Result kinds: v128, v256, u32, u64, store.
M = []


def m(enum, key, ada, c, res, imms=None, width=V128):
    M.append((enum, key, ada, c, res, imms, width))


def lanes(fn, n):
    return ', '.join('A%02d => %s ({A}, %d)' % (i, fn, i) for i in range(n))


def clanes(fn, cast, n):
    return ', '.join('(%s)%s({A}, %d)' % (cast, fn, i) for i in reversed(range(n)))


su, mm = 'x86_sse42_utility.', 'x86_m128i.'
m('Make_M128i_Multiple_U8', su + 'make_m128i_multiple_u8',
  S + 'Make_M128i_Multiple_U8 (' + lanes('U8_Lane', 16) + ')',
  '_mm_set_epi8(' + clanes('u8_lane', 'int8_t', 16) + ')', V128)
m('Make_M128i_Multiple_U32', su + 'make_m128i_multiple_u32',
  S + 'Make_M128i_Multiple_U32 (' + lanes('U32_Lane', 4) + ')',
  '_mm_set_epi32(' + clanes('u32_lane', 'int32_t', 4) + ')', V128)
m('Make_M128i_Repeat_U8', su + 'make_m128i_repeat_u8', S + 'Make_M128i_Repeat_U8 (U8_Lane ({A}, 0))',
  '_mm_set1_epi8((int8_t)u8_lane({A}, 0))', V128)
m('Make_M128i_Repeat_U16', su + 'make_m128i_repeat_u16', S + 'Make_M128i_Repeat_U16 (U16_Lane ({A}, 0))',
  '_mm_set1_epi16((int16_t)u16_lane({A}, 0))', V128)
m('Make_M128i_Single_U32', su + 'make_m128i_single_u32', S + 'Make_M128i_Single_U32 (U32_Lane ({A}, 0))',
  '_mm_cvtsi32_si128((int32_t)u32_lane({A}, 0))', V128)
m('Make_M128i_Single_U64', su + 'make_m128i_single_u64', S + 'Make_M128i_Single_U64 (U64_Lane ({A}, 0))',
  '_mm_cvtsi64_si128((int64_t)u64_lane({A}, 0))', V128)
m('Make_M128i_Slice128', su + 'make_m128i_slice128', S + 'Make_M128i_Slice128 (Byte_Buf (W ({N}) .. W ({N}) + 15))',
  '_mm_lddqu_si128((const __m128i*)(const void*)(byte_buf + ({N} % 64)))', V128)
m('Make_M128i_Slice_U16lex8', su + 'make_m128i_slice_u16lex8',
  S + 'Make_M128i_Slice_U16lex8 (U16_Buf (H ({N}) .. H ({N}) + 7))',
  '_mm_lddqu_si128((const __m128i*)(const void*)(u16_buf + ({N} % 32)))', V128)
m('Make_M128i_Zeroes', su + 'make_m128i_zeroes', S + 'Make_M128i_Zeroes', '_mm_setzero_si128()', V128)
m('Make_U64_Slice_U16lex4', su + 'make_u64_slice_u16lex4', S + 'Make_U64_Slice_U16lex4 (U16_Buf (H ({N}) .. H ({N}) + 3))',
  'wuffs_base__peek_u64le__no_bounds_check((const uint8_t*)(const void*)(u16_buf + ({N} % 32)))', 'u64')
m('Store_Slice128', mm + 'store_slice128', S + 'Store_Slice128 (X => {A}, A => Store_Buf (W ({N}) .. W ({N}) + 15))',
  '_mm_storeu_si128((__m128i*)(void*)(store_buf + ({N} % 64)), {A})', 'store')
m('Truncate_U32', mm + 'truncate_u32', S + 'Truncate_U32 ({A})', '(uint32_t)(_mm_cvtsi128_si32({A}))', 'u32')
m('Truncate_U64', mm + 'truncate_u64', S + 'Truncate_U64 ({A})', '(uint64_t)(_mm_cvtsi128_si64({A}))', 'u64')
m('Mm_Abs_Epi16', mm + '_mm_abs_epi16', S + 'Mm_Abs_Epi16 ({A})', '_mm_abs_epi16({A})', V128)
for name in ['add_epi8', 'add_epi16', 'add_epi32', 'and_si128', 'avg_epu8', 'cmpeq_epi16', 'madd_epi16',
             'maddubs_epi16', 'min_epi16', 'or_si128', 'packs_epi16', 'packus_epi16', 'sad_epu8', 'sub_epi8',
             'sub_epi16', 'unpacklo_epi8', 'xor_si128']:
    ada = 'Mm_' + '_'.join(p.capitalize() for p in name.split('_'))
    m(ada, mm + '_mm_' + name, S + ada + ' (X => {A}, B => {B})', '_mm_%s({A}, {B})' % name, V128)
m('Mm_Blendv_Epi8', mm + '_mm_blendv_epi8', S + 'Mm_Blendv_Epi8 (X => {A}, B => {B}, Mask => {C})',
  '_mm_blendv_epi8({A}, {B}, {C})', V128)
m('Mm_Clmulepi64_Si128', mm + '_mm_clmulepi64_si128', S + 'Mm_Clmulepi64_Si128 (X => {A}, B => {B}, Imm8 => {I})',
  '_mm_clmulepi64_si128({A}, {B}, {I})', V128, [0x00, 0x01, 0x10, 0x11, 0x0F, 0xF0, 0xFE, 0xFF])
m('Mm_Extract_Epi32', mm + '_mm_extract_epi32', S + 'Mm_Extract_Epi32 (X => {A}, Imm8 => {I})',
  '(uint32_t)(_mm_extract_epi32({A}, {I}))', 'u32', [0, 1, 2, 3])
m('Mm_Extract_Epi64', mm + '_mm_extract_epi64', S + 'Mm_Extract_Epi64 (X => {A}, Imm8 => {I})',
  '(uint64_t)(_mm_extract_epi64({A}, {I}))', 'u64', [0, 1])
m('Mm_Shuffle_Epi32', mm + '_mm_shuffle_epi32', S + 'Mm_Shuffle_Epi32 (X => {A}, Imm8 => {I})',
  '_mm_shuffle_epi32({A}, {I})', V128, SHUF)
m('Mm_Slli_Epi32', mm + '_mm_slli_epi32', S + 'Mm_Slli_Epi32 (X => {A}, Imm8 => {I})',
  '_mm_slli_epi32({A}, (int32_t)({I}))', V128, SH32)
m('Mm_Slli_Si128', mm + '_mm_slli_si128', S + 'Mm_Slli_Si128 (X => {A}, Imm8 => {I})',
  '_mm_slli_si128({A}, (int32_t)({I}))', V128, [0, 1, 7, 8, 15, 16, 17, 255])

au, m2 = 'x86_avx2_utility.', 'x86_m256i.'
m('Make_M256i_Multiple_U16', au + 'make_m256i_multiple_u16',
  X + 'Make_M256i_Multiple_U16 (' + lanes('U16_Lane', 16) + ')',
  '_mm256_set_epi16(' + clanes('u16_lane', 'int16_t', 16) + ')', V256, width=V256)
m('Make_M256i_Slice_U16lex16', au + 'make_m256i_slice_u16lex16',
  X + 'Make_M256i_Slice_U16lex16 (U16_Buf (H ({N}) .. H ({N}) + 15))',
  '_mm256_lddqu_si256((const __m256i*)(const void*)(u16_buf + ({N} % 32)))', V256, width=V256)
m('Make_U64_Slice_U16lex4_256', au + 'make_u64_slice_u16lex4',
  X + 'Make_U64_Slice_U16lex4 (U16_Buf (H ({N}) .. H ({N}) + 3))',
  'wuffs_base__peek_u64le__no_bounds_check((const uint8_t*)(const void*)(u16_buf + ({N} % 32)))', 'u64')
for name in ['add_epi8', 'add_epi16', 'add_epi32', 'madd_epi16', 'mullo_epi16', 'packs_epi16', 'packs_epi32',
             'sign_epi16', 'sub_epi32', 'unpackhi_epi16', 'unpackhi_epi64', 'unpacklo_epi16', 'unpacklo_epi64']:
    ada = 'Mm256_' + '_'.join(p.capitalize() for p in name.split('_'))
    m(ada, m2 + '_mm256_' + name, X + ada + ' (X => {A}, B => {B})', '_mm256_%s({A}, {B})' % name, V256,
      width=V256)
m('Mm256_Castsi256_Si128', m2 + '_mm256_castsi256_si128', X + 'Mm256_Castsi256_Si128 ({A})',
  '_mm256_castsi256_si128({A})', V128, width=V256)
m('Mm256_Extract_Epi64', m2 + '_mm256_extract_epi64', X + 'Mm256_Extract_Epi64 (X => {A}, Index => {I})',
  '(uint64_t)(_mm256_extract_epi64({A}, (int32_t)({I})))', 'u64', [0, 1, 2, 3], width=V256)
m('Mm256_Inserti128_Si256', m2 + '_mm256_inserti128_si256',
  X + 'Mm256_Inserti128_Si256 (X => {A}, B => {C}, Imm8 => {I})',
  '_mm256_inserti128_si256({A}, {C}, (int32_t)({I}))', V256, [0, 1], width=V256)
m('Mm256_Permute2x128_Si256', m2 + '_mm256_permute2x128_si256',
  X + 'Mm256_Permute2x128_Si256 (X => {A}, B => {B}, Imm8 => {I})',
  '_mm256_permute2x128_si256({A}, {B}, (int32_t)({I}))', V256,
  [0x00, 0x01, 0x02, 0x03, 0x10, 0x20, 0x31, 0x08, 0x80, 0x88, 0x13, 0x32, 0x21, 0x12, 0xFF, 0x30, 0x23],
  width=V256)
m('Mm256_Permute4x64_Epi64', m2 + '_mm256_permute4x64_epi64', X + 'Mm256_Permute4x64_Epi64 (X => {A}, Imm8 => {I})',
  '_mm256_permute4x64_epi64({A}, (int32_t)({I}))', V256, [0x00, 0x1B, 0x4E, 0xB1, 0xE4, 0xFF, 0x72, 0xD8, 0x39, 0x93],
  width=V256)
m('Mm256_Shuffle_Epi32', m2 + '_mm256_shuffle_epi32', X + 'Mm256_Shuffle_Epi32 (X => {A}, Imm8 => {I})',
  '_mm256_shuffle_epi32({A}, (int32_t)({I}))', V256, SHUF, width=V256)
m('Mm256_Slli_Epi16', m2 + '_mm256_slli_epi16', X + 'Mm256_Slli_Epi16 (X => {A}, Imm8 => {I})',
  '_mm256_slli_epi16({A}, (int32_t)({I}))', V256, [0, 1, 2, 7, 15, 16, 17, 255], width=V256)
m('Mm256_Srai_Epi32', m2 + '_mm256_srai_epi32', X + 'Mm256_Srai_Epi32 (X => {A}, Imm8 => {I})',
  '_mm256_srai_epi32({A}, (int32_t)({I}))', V256, [0, 1, 11, 16, 18, 30, 31, 32, 33, 255], width=V256)

HELPERS = '''   function To_M128I (X : Bytes32) return M128I is
      B : Bytes16;
   begin
      for I in B'Range loop
         B (I) := X (I);
      end loop;
      return B16_To_M128I (B);
   end To_M128I;

   function From_M128I (X : M128I) return Bytes32 is
      B : constant Bytes16 := M128I_To_B16 (X);
      R : Bytes32 := [others => 0];
   begin
      for I in B'Range loop
         R (I) := B (I);
      end loop;
      return R;
   end From_M128I;

   function From_U32 (X : Unsigned_32) return Bytes32 is
      R : Bytes32 := [others => 0];
   begin
      for I in 0 .. 3 loop
         R (I) := Unsigned_8 (Shift_Right (X, 8 * I) and 16#FF#);
      end loop;
      return R;
   end From_U32;

   function From_U64 (X : Unsigned_64) return Bytes32 is
      R : Bytes32 := [others => 0];
   begin
      for I in 0 .. 7 loop
         R (I) := Unsigned_8 (Shift_Right (X, 8 * I) and 16#FF#);
      end loop;
      return R;
   end From_U64;

'''

N_INPUTS = 96
CHECKPOINT = 16  # A digest after every 16 inputs: 6 per method.

HDR = ('--  Part of wuffada (wuffs-ada: Wuffs to Ada).\n'
       '--  SPDX-License-Identifier: Apache-2.0 OR MIT\n\n'
       '--  Generated by ada/tests/simd/oracle/gen.py from its method table.  Do not edit.\n')


def wrapcall(prefix, call, suffix):
    line = prefix + call + suffix
    if len(line) <= 100 or ' (' not in call:
        return [line]
    i = call.index(' (')
    head, args = call[:i], call[i + 2:-1]
    parts, depth, cur = [], 0, ''
    for ch in args:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
    parts.append(cur.strip())
    ind = ' ' * (len(prefix) + 2)
    out = [prefix + head]
    for k, p in enumerate(parts):
        out.append(ind + ('(' if k == 0 else ' ') + p + (',' if k < len(parts) - 1 else ')' + suffix))
    return out


def gen_methods_ads():
    L = [HDR, 'package X86_Methods is', '']
    L.append('   --  One per wrapper of Wuffs.Runtime.X86.SSE42 and AVX2 (see x86_methods.list).')
    L.append('   type Method is')
    L.append('     (' + ',\n      '.join(x[0] for x in M) + ');')
    L.append('')
    L.append('   Number_Of_Inputs : constant := %d;' % N_INPUTS)
    L.append('   Checkpoint_Every : constant := %d;' % CHECKPOINT)
    L.append('   Number_Of_Checkpoints : constant := %d;' % (N_INPUTS // CHECKPOINT))
    L.append('')
    L.append('   --  The immediate arguments tested, for the methods that take one.')
    L.append('   type Imm_Array is array (1 .. 20) of Integer;')
    L.append('   type Imm_List is record')
    L.append('      N : Natural := 0;')
    L.append('      V : Imm_Array := [others => 0];')
    L.append('   end record;')
    L.append('   Imms : constant array (Method) of Imm_List :=')
    items = []
    for x in M:
        if x[5]:
            nums = [str(v) for v in x[5] + [0] * (20 - len(x[5]))]
            lines, cur = [], ''
            for k, v in enumerate(nums):
                piece = v + (', ' if k < len(nums) - 1 else '')
                if len(cur) + len(piece) > 70:
                    lines.append(cur.rstrip())
                    cur = ''
                cur += piece
            lines.append(cur)
            items.append('%s =>\n        (N => %d,\n         V => [%s])' %
                         (x[0], len(x[5]), ('\n' + ' ' * 18).join(lines)))
    items.append('others => (N => 0, V => [others => 0])')
    L.append('     [' + ',\n      '.join(items) + '];')
    L.append('')
    L.append('end X86_Methods;')
    open(os.path.join(up, 'x86_methods.ads'), 'w').write('\n'.join(L) + '\n')
    open(os.path.join(up, 'x86_methods.list'), 'w').write(
        '# Generated by ada/tests/simd/oracle/gen.py: the Wuffs method of each\n'
        '# wrapper that x86_test_cases.adb and the oracle test.\n' +
        ''.join('%s %s\n' % (x[1], x[0]) for x in M))


def gen_test_cases_adb():
    B = [HDR]
    B.append('with Wuffs.Runtime.X86.AVX2;')
    B.append('with Wuffs.Runtime.X86.SSE42;')
    B.append('')
    B.append('package body X86_Test_Cases is')
    B.append('')
    B.extend(HELPERS.rstrip('\n').split('\n'))
    B.append('')
    B.append('   function Apply (M : Method; Imm : Integer; N : Natural; A, B, C : Bytes32) return Bytes32 is')
    B.append('      A1 : constant M128I := To_M128I (A);')
    B.append('      B1 : constant M128I := To_M128I (B);')
    B.append('      C1 : constant M128I := To_M128I (C);')
    B.append('      A2 : constant M256I := To_M256I (A);')
    B.append('      B2 : constant M256I := To_M256I (B);')
    B.append('   begin')
    B.append('      case M is')
    for (enum, key, ada, c, res, imms, width) in M:
        sub = dict(A='A1', B='B1', C='C1', N='N') if width == V128 else dict(A='A2', B='B2', C='C1', N='N')
        if enum.startswith('Make_') and '{N}' not in ada:
            sub = dict(A='A', B='B', C='C', N='N')
        B.append('         when %s =>' % enum)
        if res == 'store':
            B.extend(wrapcall('            ', ada.format(**sub), ';'))
            B.append('            return [others => 0];')
            continue
        wrap = {'v128': 'From_M128I', 'v256': 'From_M256I', 'u32': 'From_U32', 'u64': 'From_U64'}[res]
        if imms:
            B.append('            case Imm is')
            for v in imms:
                B.append('               when %d =>' % v)
                B.append('                  return %s' % wrap)
                B.extend(wrapcall('                    (', ada.format(I=str(v), **sub), ');'))
            B.append('               when others =>')
            B.append('                  raise Program_Error;')
            B.append('            end case;')
        else:
            B.append('            return %s' % wrap)
            B.extend(wrapcall('              (', ada.format(**sub), ');'))
    B.append('      end case;')
    B.append('   end Apply;')
    B.append('')
    B.append('end X86_Test_Cases;')
    open(os.path.join(up, 'x86_test_cases.adb'), 'w').write('\n'.join(B) + '\n')


def gen_oracle_c():
    C = ['''// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// Generated by gen.py from its method table. Do not edit.
//
// The oracle of test_x86: every Wuffs x86 cpu_arch method that the Ada
// generator can emit, computed with the _mm_* / _mm256_* intrinsic that
// upstream's C back-end calls for it (wuffs/internal/cgen/builtin.go,
// writeBuiltinCPUArchX86, with its casts), over the inputs of test_x86, and
// printed as checkpointed FNV-1a digests in the form of an Ada aggregate
// (regen.sh writes them into ../x86_oracle_data.ads).
//
// Build: cc -O2 -msse4.2 -mpclmul -mpopcnt -mavx2 -mbmi2 x86_oracle.c
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <x86intrin.h>

typedef struct { uint8_t b[32]; } bytes32;

static uint8_t u8_lane(bytes32 x, int i) { return x.b[i]; }
static uint16_t u16_lane(bytes32 x, int i) { return (uint16_t)(x.b[2*i] | (x.b[2*i+1] << 8)); }
static uint32_t u32_lane(bytes32 x, int i) {
  return (uint32_t)u16_lane(x, 2*i) | ((uint32_t)u16_lane(x, 2*i+1) << 16);
}
static uint64_t u64_lane(bytes32 x, int i) {
  return (uint64_t)u32_lane(x, 2*i) | ((uint64_t)u32_lane(x, 2*i+1) << 32);
}
// As upstream's base library (fundamental-public.h).
static uint64_t wuffs_base__peek_u64le__no_bounds_check(const uint8_t* p) {
  return ((uint64_t)(p[0]) << 0) | ((uint64_t)(p[1]) << 8) | ((uint64_t)(p[2]) << 16) |
         ((uint64_t)(p[3]) << 24) | ((uint64_t)(p[4]) << 32) | ((uint64_t)(p[5]) << 40) |
         ((uint64_t)(p[6]) << 48) | ((uint64_t)(p[7]) << 56);
}
static __m128i v128(bytes32 x) { return _mm_loadu_si128((const __m128i*)(const void*)x.b); }
static __m256i v256(bytes32 x) { return _mm256_loadu_si256((const __m256i*)(const void*)x.b); }
static bytes32 of128(__m128i v) { bytes32 r; memset(&r, 0, 32); _mm_storeu_si128((__m128i*)(void*)r.b, v); return r; }
static bytes32 of256(__m256i v) { bytes32 r; _mm256_storeu_si256((__m256i*)(void*)r.b, v); return r; }
static bytes32 ofu32(uint32_t v) {
  bytes32 r; memset(&r, 0, 32); for (int i = 0; i < 4; i++) { r.b[i] = (uint8_t)(v >> (8*i)); } return r;
}
static bytes32 ofu64(uint64_t v) {
  bytes32 r; memset(&r, 0, 32); for (int i = 0; i < 8; i++) { r.b[i] = (uint8_t)(v >> (8*i)); } return r;
}

// The inputs, as Input in test_x86.adb: 26 vectors of repeated edge-case
// 16-bit lanes (0, -1, the saturation bounds, sign bits), then
// pseudo-random ones.
static const uint16_t patterns[13] = {0x0000, 0xFFFF, 0x7FFF, 0x8000, 0x7F7F, 0x8080, 0x0001,
                                      0x00FF, 0xFF00, 0x8001, 0x7FFE, 0xFF7F, 0x80FF};
static bytes32 input(int n) {
  bytes32 r;
  if (n < 26) {
    for (int j = 0; j < 16; j++) {
      uint16_t p = patterns[(n < 13) ? n : ((n + j) % 13)];
      r.b[2*j] = (uint8_t)p; r.b[2*j+1] = (uint8_t)(p >> 8);
    }
    return r;
  }
  uint64_t s = 0x9E3779B97F4A7C15ull * (uint64_t)(n + 1);
  for (int j = 0; j < 32; j++) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    r.b[j] = (uint8_t)(s >> 24);
  }
  return r;
}

// The buffers of the loads and the store, 64-aligned: input N loads from
// (or stores to) offset N % 64 (bytes) or N % 32 (u16 elements).
static uint8_t byte_buf[160] __attribute__((aligned(64)));
static uint16_t u16_buf[96] __attribute__((aligned(64)));
static uint8_t store_buf[160] __attribute__((aligned(64)));

static uint64_t digest;
static void eat(const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) { digest = (digest ^ p[i]) * 0x100000001B3ull; }
}

int main(void) {
  for (int i = 0; i < 160; i++) { byte_buf[i] = (uint8_t)((i * 37 + 11) % 256); }
  for (int i = 0; i < 96; i++) { u16_buf[i] = (uint16_t)((i * 4099 + 7) % 65536); }
''']
    for (enum, key, ada, c, res, imms, width) in M:
        conv = 'v128' if width == V128 else 'v256'
        sub = dict(A='%s(a)' % conv, B='%s(b)' % conv, C='v128(c)', N='n')
        if enum.startswith('Make_') and '{N}' not in ada:
            sub = dict(A='a', B='b', C='c', N='n')
        C.append('  printf("      %s =>\\n        [");' % enum)
        C.append('  digest = 0xCBF29CE484222325ull;')
        C.append('  for (int n = 0; n < %d; n++) {' % N_INPUTS)
        C.append('    bytes32 a = input(n), b = input((n * 7 + 3) %% %d), c = input((n * 5 + 11) %% %d);'
                 % (N_INPUTS, N_INPUTS))
        C.append('    (void)a; (void)b; (void)c;')
        for v in (imms or [0]):
            e = c.format(I=str(v), **sub)
            if res == 'store':
                C.append('    memset(store_buf, 0xA5, sizeof store_buf);')
                C.append('    %s;' % e)
                C.append('    eat(store_buf, sizeof store_buf);')
            else:
                wrap = {'v128': 'of128', 'v256': 'of256', 'u32': 'ofu32', 'u64': 'ofu64'}[res]
                C.append('    { bytes32 r = %s(%s); eat(r.b, 32); }' % (wrap, e))
        C.append('    if ((n + 1) %% %d == 0) {' % CHECKPOINT)
        C.append('      printf("16#%%016" PRIX64 "#%%s", digest, (n + 1 == %d) ? "]" : ",\\n         ");'
                 % N_INPUTS)
        C.append('    }')
        C.append('  }')
        C.append('  printf("%s\\n");' % (',' if enum != M[-1][0] else ''))
    C.append('  return 0;')
    C.append('}')
    open(os.path.join(here, 'x86_oracle.c'), 'w').write('\n'.join(C) + '\n')


gen_methods_ads()
gen_test_cases_adb()
gen_oracle_c()
