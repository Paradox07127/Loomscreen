# Stage F — Shader Transpile (WPE GLSL → Metal MSL)

**Two-stage path:** `WPERenderPipelineBuilder.preprocess()` prepends `shaderPrelude` (CAST/lerp/saturate/texSample2D #defines, :869-922) + `expandIncludes` (common.h/common_blending.h) **before** `WPEShaderPreprocessor` → `WPEShaderTranspiler`. Several builtins resolve upstream.

## Checklist (abridged to ❌/⚠️ + key ✅)

| feature/builtin | impl (file:line) | verdict | note |
|---|---|---|---|
| vec/mat → float/floatNxN | Transpiler:637-645 | ✅ | |
| mix/lerp/frac/fract/saturate/atan2/mod/fmod/mul | Transpiler + Builder prelude | ✅ | mul = `((y)*(x))` swap (correct) |
| ddx/ddy → dFdx/dFdy | Builder:881-882 | ⚠️ | should be `dfdx/dfdy` (MSL); no negation (correct for Metal) |
| CAST2/3/4 / CAST3X3 | Builder:884-887 | ✅ | survives → Metal preproc expands |
| **CAST4X4** | — | ❌ | undefined → literal text → MSL compile fail |
| texSample2D → .sample | Builder:878→texture()→Transpiler:1206 | ✅ | |
| **texSample2DLod** | Preproc:196→textureLod(; Transpiler only rewrites texture( | ❌ | textureLod survives → MSL compile fail |
| texSampleNorm2D | Preproc:198→texture() | ⚠️ | loses normal-map decompress |
| g_TextureN sampler (slot fix) | Transpiler:2083,1713-1716 | ✅ | g_TextureN→texN slot fix correct |
| slot 0-3 guard | Transpiler:108-112 | ✅ | rejects slot ≥4 explicitly |
| #include common.h / common_blending.h / ApplyBlending | Builder:924,1027-1092 | ✅ | inlined upstream |
| M_PI / M_PI_2(=2π) | Builder:888-903 | ⚠️ | M_PI_2 ambiguity (WPE convention) |
| #if/#ifdef/#elif/#else / defined() | Transpiler:194-289,488-501 | ✅ | nested frames correct |
| **unsupported #if expr → 0** | Transpiler:341 (`?? 0`) | ❌ | silent wrong branch |
| **main() detection** | Transpiler:585-600 | ⚠️ | raw "void main" substring |
| gl_FragColor/out_FragColor → out_color | Preproc:200-201; Transpiler:609-621 | ✅ | |
| varying / v_TexCoord | Transpiler:1772-1785,1959-2059 | ⚠️ | derived from in.uv heuristics; .zw approximated |
| gl_FragCoord | Transpiler:113 | ⚠️ | presence flag only; no usable alias |

## Deviations

- **❌ HIGH — `texSample2DLod` → uncompilable MSL.** `WPEShaderPreprocessor:196` maps to `textureLod(`, but `Transpiler.rewriteTextureCalls:1206-1250` only matches `texture(`. Any LOD/mip/blur/bloom shader emits literal `textureLod(...)` → `makeLibrary` fails → fallback/black. Fix: rewrite `textureLod(` → `.sample(linearSampler, uv, level(lod))`.
- **❌ HIGH — unsupported `#if` → 0.** `evaluatePreprocessorExpression:341` returns `?? 0`; tokenizer (:564-572) lacks `* / % ~ << >>`, ternary, func-macros → any such combo branch silently takes the 0 path → wrong shader variant, no error.
- **❌ MED — `CAST4X4` not provided.** Builder defines CAST2/3/4/CAST3X3 only → `CAST4X4(...)` survives → MSL undefined-identifier fail.
- **⚠️ MED — `ddx/ddy` → `dFdx/dFdy` (not MSL).** Should be `dfdx/dfdy`. (And must NOT negate ddy — correct on Metal; do not copy GL's `dFdy(-x)`.)
- **⚠️ MED — `main()` raw substring search.** Comment/helper/string `void main` mis-anchors entry point.
- **⚠️ MED — `texSampleNorm2D` collapses to plain sample.** Loses DXT5nm `DecompressNormal` → normal-map lighting wrong.
- **⚠️ LOW — varying derivation heuristic/lossy** (custom `v_TexCoord.zw` approximated).
- **⚠️ LOW — slots 0-3 only (doc 0-7).** Intentional guard; correctly fails-closed rather than mis-render.

**Positives:** type/intrinsic core map sound; g_TextureN→texN slot fix + 0-3 guard correct (this session's fix); nested #if/defined() correct; gl_FragColor unification consistent; CAST2/3/4/CAST3X3/common.h/ApplyBlending/M_PI/saturate/mul resolved upstream.

Sources: docs shader/syntax, headers, variables, overview.
