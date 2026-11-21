# The x86 cpu_arch methods: Wuffs method, C intrinsic, GCC builtin

Every Wuffs x86 cpu_arch method that wuffs-ada can generate code for (the table
`x86Methods` in internal/adagen/simd.go; the wrapper tests cover the same list,
ada/tests/simd/x86_methods.list, and a Go test checks that the two agree). Each
is one Ada subprogram, named after the method, in `Wuffs.Runtime.X86.SSE42`
(base.x86_sse42_utility, base.x86_m128i) or `Wuffs.Runtime.X86.AVX2`
(base.x86_avx2_utility, base.x86_m256i).

* **Intrinsic**: what upstream's C back-end emits for the method
  (wuffs/internal/cgen/builtin.go, `writeBuiltinCPUArchX86`, at a87f0bb).
* **Builtin**: what the Ada wrapper calls, as GCC's own header
  (lib/gcc/x86_64-pc-linux-gnu/16.1.0/include/*intrin.h) defines the intrinsic;
  the vector type in parentheses is the lane view the builtin's prototype
  needs. Where the header uses a GCC vector operator rather than a builtin
  (noted), the wrapper calls the builtin of the same instruction and semantics.
  "(aggregate)" and "(Ada)" mean no builtin: the lanes are built or read in Ada.
* Immediates must be static and in the range given; the generator rejects any
  other argument at generation time.

Every other method of the x86 types in wuffs/lang/builtin/builtin.go is
rejected at generation time ("not yet supported: the cpu_arch method ...");
none of Wuffs' standard library calls one. The ARM types and methods are not
supported (their functions are skipped), and `x86_bmi2` has no methods.

| Wuffs method | Ada subprogram | Intrinsic | Builtin | Note |
|---|---|---|---|---|
| `x86_sse42_utility.make_m128i_multiple_u8` | `SSE42.Make_M128i_Multiple_U8` | `_mm_set_epi8 (a15..a00, int8_t casts)` | (aggregate) U8x16 [a00..a15] | header: vector literal |
| `x86_sse42_utility.make_m128i_multiple_u32` | `SSE42.Make_M128i_Multiple_U32` | `_mm_set_epi32 (a03..a00, int32_t casts)` | (aggregate) U32x4 [a00..a03] | header: vector literal |
| `x86_sse42_utility.make_m128i_repeat_u8` | `SSE42.Make_M128i_Repeat_U8` | `_mm_set1_epi8` | (aggregate) U64x2 of a * 16#0101_0101_0101_0101# | not `[others => a]`: GNAT 16.1 miscompiles that for 8-bit vector lanes |
| `x86_sse42_utility.make_m128i_repeat_u16` | `SSE42.Make_M128i_Repeat_U16` | `_mm_set1_epi16` | (aggregate) U64x2 of a * 16#0001_0001_0001_0001# |  |
| `x86_sse42_utility.make_m128i_single_u32` | `SSE42.Make_M128i_Single_U32` | `_mm_cvtsi32_si128` | (aggregate) U32x4 [a, 0, 0, 0] | header: _mm_set_epi32 (0, 0, 0, a) |
| `x86_sse42_utility.make_m128i_single_u64` | `SSE42.Make_M128i_Single_U64` | `_mm_cvtsi64_si128` | (aggregate) U64x2 [a, 0] | header: _mm_set_epi64x (0, a) |
| `x86_sse42_utility.make_m128i_slice128` | `SSE42.Make_M128i_Slice128` | `_mm_lddqu_si128` | __builtin_ia32_lddqu | Pre: A'Length >= 16 |
| `x86_sse42_utility.make_m128i_slice_u16lex8` | `SSE42.Make_M128i_Slice_U16lex8` | `_mm_lddqu_si128` | __builtin_ia32_lddqu | Pre: A'Length >= 8 (u16) |
| `x86_sse42_utility.make_m128i_zeroes` | `SSE42.Make_M128i_Zeroes` | `_mm_setzero_si128` | (constant) Zero_M128I |  |
| `x86_sse42_utility.make_u64_slice_u16lex4` | `SSE42.Make_U64_Slice_U16lex4` | `wuffs_base__peek_u64le__no_bounds_check` | (Ada) four u16, little-endian | Pre: A'Length >= 4 (u16) |
| `x86_m128i.store_slice128` | `SSE42.Store_Slice128` | `_mm_storeu_si128` | __builtin_ia32_storedqu | header: assignment through __m128i_u*; Pre: A'Length >= 16 |
| `x86_m128i.truncate_u32` | `SSE42.Truncate_U32` | `_mm_cvtsi128_si32` | __builtin_ia32_vec_ext_v4si (x, 0) |  |
| `x86_m128i.truncate_u64` | `SSE42.Truncate_U64` | `_mm_cvtsi128_si64` | (Ada) lane 0 of the v2di view | header: ((__v2di)a)[0] |
| `x86_m128i._mm_abs_epi16` | `SSE42.Mm_Abs_Epi16` | `_mm_abs_epi16` | __builtin_ia32_pabsw128 (v8hi) |  |
| `x86_m128i._mm_add_epi8` | `SSE42.Mm_Add_Epi8` | `_mm_add_epi8` | __builtin_ia32_paddb128 (v16qi) | header: vector + |
| `x86_m128i._mm_add_epi16` | `SSE42.Mm_Add_Epi16` | `_mm_add_epi16` | __builtin_ia32_paddw128 (v8hi) | header: vector + |
| `x86_m128i._mm_add_epi32` | `SSE42.Mm_Add_Epi32` | `_mm_add_epi32` | __builtin_ia32_paddd128 (v4si) | header: vector + |
| `x86_m128i._mm_and_si128` | `SSE42.Mm_And_Si128` | `_mm_and_si128` | __builtin_ia32_pand128 (v2di) | header: vector & |
| `x86_m128i._mm_avg_epu8` | `SSE42.Mm_Avg_Epu8` | `_mm_avg_epu8` | __builtin_ia32_pavgb128 (v16qi) |  |
| `x86_m128i._mm_blendv_epi8` | `SSE42.Mm_Blendv_Epi8` | `_mm_blendv_epi8` | __builtin_ia32_pblendvb128 (v16qi) |  |
| `x86_m128i._mm_clmulepi64_si128` | `SSE42.Mm_Clmulepi64_Si128` | `_mm_clmulepi64_si128` | __builtin_ia32_pclmulqdq128 (v2di, imm8) | imm8 0 ..= 255 |
| `x86_m128i._mm_cmpeq_epi16` | `SSE42.Mm_Cmpeq_Epi16` | `_mm_cmpeq_epi16` | __builtin_ia32_pcmpeqw128 (v8hi) | header: vector == |
| `x86_m128i._mm_extract_epi32` | `SSE42.Mm_Extract_Epi32` | `_mm_extract_epi32` | __builtin_ia32_vec_ext_v4si | imm8 0 ..= 3 |
| `x86_m128i._mm_extract_epi64` | `SSE42.Mm_Extract_Epi64` | `_mm_extract_epi64` | __builtin_ia32_vec_ext_v2di | imm8 0 ..= 1 |
| `x86_m128i._mm_madd_epi16` | `SSE42.Mm_Madd_Epi16` | `_mm_madd_epi16` | __builtin_ia32_pmaddwd128 (v8hi -> v4si) |  |
| `x86_m128i._mm_maddubs_epi16` | `SSE42.Mm_Maddubs_Epi16` | `_mm_maddubs_epi16` | __builtin_ia32_pmaddubsw128 (v16qi -> v8hi) |  |
| `x86_m128i._mm_min_epi16` | `SSE42.Mm_Min_Epi16` | `_mm_min_epi16` | __builtin_ia32_pminsw128 (v8hi) |  |
| `x86_m128i._mm_or_si128` | `SSE42.Mm_Or_Si128` | `_mm_or_si128` | __builtin_ia32_por128 (v2di) | header: vector | |
| `x86_m128i._mm_packs_epi16` | `SSE42.Mm_Packs_Epi16` | `_mm_packs_epi16` | __builtin_ia32_packsswb128 (v8hi -> v16qi) |  |
| `x86_m128i._mm_packus_epi16` | `SSE42.Mm_Packus_Epi16` | `_mm_packus_epi16` | __builtin_ia32_packuswb128 (v8hi -> v16qi) |  |
| `x86_m128i._mm_sad_epu8` | `SSE42.Mm_Sad_Epu8` | `_mm_sad_epu8` | __builtin_ia32_psadbw128 (v16qi -> v2di) |  |
| `x86_m128i._mm_shuffle_epi32` | `SSE42.Mm_Shuffle_Epi32` | `_mm_shuffle_epi32` | __builtin_ia32_pshufd (v4si, imm8) | imm8 0 ..= 255 |
| `x86_m128i._mm_slli_epi32` | `SSE42.Mm_Slli_Epi32` | `_mm_slli_epi32` | __builtin_ia32_pslldi128 (v4si, count) | imm8 0 ..= 255 |
| `x86_m128i._mm_slli_si128` | `SSE42.Mm_Slli_Si128` | `_mm_slli_si128` | __builtin_ia32_pslldqi128 (v2di, imm8 * 8) | imm8 0 ..= 255 |
| `x86_m128i._mm_sub_epi8` | `SSE42.Mm_Sub_Epi8` | `_mm_sub_epi8` | __builtin_ia32_psubb128 (v16qi) | header: vector - |
| `x86_m128i._mm_sub_epi16` | `SSE42.Mm_Sub_Epi16` | `_mm_sub_epi16` | __builtin_ia32_psubw128 (v8hi) | header: vector - |
| `x86_m128i._mm_unpacklo_epi8` | `SSE42.Mm_Unpacklo_Epi8` | `_mm_unpacklo_epi8` | __builtin_ia32_punpcklbw128 (v16qi) |  |
| `x86_m128i._mm_xor_si128` | `SSE42.Mm_Xor_Si128` | `_mm_xor_si128` | __builtin_ia32_pxor128 (v2di) | header: vector ^ |
| `x86_avx2_utility.make_m256i_multiple_u16` | `AVX2.Make_M256i_Multiple_U16` | `_mm256_set_epi16 (a15..a00, int16_t casts)` | (aggregate) U16x16 [a00..a15] |  |
| `x86_avx2_utility.make_m256i_slice_u16lex16` | `AVX2.Make_M256i_Slice_U16lex16` | `_mm256_lddqu_si256` | __builtin_ia32_lddqu256 | Pre: A'Length >= 16 (u16) |
| `x86_avx2_utility.make_u64_slice_u16lex4` | `AVX2.Make_U64_Slice_U16lex4` | `wuffs_base__peek_u64le__no_bounds_check` | (Ada) four u16, little-endian | Pre: A'Length >= 4 (u16) |
| `x86_m256i._mm256_add_epi8` | `AVX2.Mm256_Add_Epi8` | `_mm256_add_epi8` | __builtin_ia32_paddb256 (v32qi) | header: vector + |
| `x86_m256i._mm256_add_epi16` | `AVX2.Mm256_Add_Epi16` | `_mm256_add_epi16` | __builtin_ia32_paddw256 (v16hi) | header: vector + |
| `x86_m256i._mm256_add_epi32` | `AVX2.Mm256_Add_Epi32` | `_mm256_add_epi32` | __builtin_ia32_paddd256 (v8si) | header: vector + |
| `x86_m256i._mm256_castsi256_si128` | `AVX2.Mm256_Castsi256_Si128` | `_mm256_castsi256_si128` | __builtin_ia32_si_si256 (v8si -> v4si) |  |
| `x86_m256i._mm256_extract_epi64` | `AVX2.Mm256_Extract_Epi64` | `_mm256_extract_epi64` | __builtin_ia32_vextractf128_si256 (v8si, n / 2), then __builtin_ia32_vec_ext_v2di (n mod 2) | index 0 ..= 3; as avxintrin.h |
| `x86_m256i._mm256_inserti128_si256` | `AVX2.Mm256_Inserti128_Si256` | `_mm256_inserti128_si256` | __builtin_ia32_insert128i256 (v4di, v2di, imm8) | imm8 0 ..= 1 |
| `x86_m256i._mm256_madd_epi16` | `AVX2.Mm256_Madd_Epi16` | `_mm256_madd_epi16` | __builtin_ia32_pmaddwd256 (v16hi -> v8si) |  |
| `x86_m256i._mm256_mullo_epi16` | `AVX2.Mm256_Mullo_Epi16` | `_mm256_mullo_epi16` | __builtin_ia32_pmullw256 (v16hi) | header: vector * |
| `x86_m256i._mm256_packs_epi16` | `AVX2.Mm256_Packs_Epi16` | `_mm256_packs_epi16` | __builtin_ia32_packsswb256 (v16hi -> v32qi) |  |
| `x86_m256i._mm256_packs_epi32` | `AVX2.Mm256_Packs_Epi32` | `_mm256_packs_epi32` | __builtin_ia32_packssdw256 (v8si -> v16hi) |  |
| `x86_m256i._mm256_permute2x128_si256` | `AVX2.Mm256_Permute2x128_Si256` | `_mm256_permute2x128_si256` | __builtin_ia32_permti256 (v4di, imm8) | imm8 0 ..= 255 |
| `x86_m256i._mm256_permute4x64_epi64` | `AVX2.Mm256_Permute4x64_Epi64` | `_mm256_permute4x64_epi64` | __builtin_ia32_permdi256 (v4di, imm8) | imm8 0 ..= 255 |
| `x86_m256i._mm256_shuffle_epi32` | `AVX2.Mm256_Shuffle_Epi32` | `_mm256_shuffle_epi32` | __builtin_ia32_pshufd256 (v8si, imm8) | imm8 0 ..= 255 |
| `x86_m256i._mm256_sign_epi16` | `AVX2.Mm256_Sign_Epi16` | `_mm256_sign_epi16` | __builtin_ia32_psignw256 (v16hi) |  |
| `x86_m256i._mm256_slli_epi16` | `AVX2.Mm256_Slli_Epi16` | `_mm256_slli_epi16` | __builtin_ia32_psllwi256 (v16hi, count) | imm8 0 ..= 255 |
| `x86_m256i._mm256_srai_epi32` | `AVX2.Mm256_Srai_Epi32` | `_mm256_srai_epi32` | __builtin_ia32_psradi256 (v8si, count) | imm8 0 ..= 255 |
| `x86_m256i._mm256_sub_epi32` | `AVX2.Mm256_Sub_Epi32` | `_mm256_sub_epi32` | __builtin_ia32_psubd256 (v8si) | header: vector - |
| `x86_m256i._mm256_unpackhi_epi16` | `AVX2.Mm256_Unpackhi_Epi16` | `_mm256_unpackhi_epi16` | __builtin_ia32_punpckhwd256 (v16hi) |  |
| `x86_m256i._mm256_unpackhi_epi64` | `AVX2.Mm256_Unpackhi_Epi64` | `_mm256_unpackhi_epi64` | __builtin_ia32_punpckhqdq256 (v4di) |  |
| `x86_m256i._mm256_unpacklo_epi16` | `AVX2.Mm256_Unpacklo_Epi16` | `_mm256_unpacklo_epi16` | __builtin_ia32_punpcklwd256 (v16hi) |  |
| `x86_m256i._mm256_unpacklo_epi64` | `AVX2.Mm256_Unpacklo_Epi64` | `_mm256_unpacklo_epi64` | __builtin_ia32_punpcklqdq256 (v4di) |  |
