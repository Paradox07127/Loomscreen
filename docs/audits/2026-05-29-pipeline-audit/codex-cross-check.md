# codex backend-authority cross-check (decode / coordinates / shader)

Independent review by codex (session `019e7251-42d5-7a60-960d-0bcb3950c6de`) of the three highest-risk stages, judged against its WPE-format knowledge + the code + real corpus. **Strongly cross-validates** the stage agents — independently reached the same Critical verdict on the Y-axis conflict, plus parallax, `#if→0`, `texSample2DLod`, slot-cap.

## 1. Texture/Model Decode — *partially matches real WPE*

- **Major — TEXS affine frame fields ignored.** `WPETexDecoder.swift:321` reduces frames to axis-aligned `CGRect`, drops `widthY`/`heightX`. Nonzero affine terms → wrong frame region/orientation.
- **Major — eager animated textures preserve `sourceSubRect` but don't crop/sample it.** `WPEMetalTextureLoader.swift:80` uploads the full atlas per frame; `WPETexAnimatedTextureSource.swift:72` returns only the texture. Small animated atlases render the whole sheet. (Lazy path crops → behavior differs by size.)
- **Major — puppet/model decode static-only.** `WPEMdlParser.swift:162/263` reads skin+skeleton, but `WPEMetalBuiltins.metal:98` renders raw positions without bones/animation. Animated puppet layers won't match.
- **Minor/Major — mipmaps discarded.** `WPEMetalTextureLoader.swift:171` `mipmapped:false`, uploads only largest mip → aliasing/incorrect minification.
- **Minor — CPU BC transcode diverges from native sampling.** `WPETexMetalTranscoder.swift:84` writes linear `.rgba8Unorm` while `WPEMetalTextureFormatMapper.swift:90` maps native BC to sRGB → gamma diff; the transcode shader also applies its own Y flip.

## 2. Coordinates/Transforms — *highest-risk; internally inconsistent*

- **Critical — Y-axis convention conflict.** `WPEMetalRuntimeUniforms.swift:204` builds top-left ortho (y=0→top), but `WPEMetalRenderExecutor.swift:903` computes object centers as `originY − sceneHeight/2` and `WPEMetalBuiltins.metal:73` maps +Y up. One side is wrong → off-center objects vertically mirrored/offset.
- **Major — parallax is a simplified UV offset, not WPE camera parallax.** `WPEMetalShaderInputs.swift:160` `(pointer−0.5)·depth·0.1` clamped 0.05; ignores `general.cameraparallax*`, camera depth/center/delay; applied only in copy paths (`:847`), not material/effect passes.
- **Major — ortho/camera uniforms not authoritative for built-in geometry.** `g_ViewProjectionMatrix` packed but object/puppet/particle/text compute NDC directly (`WPEMetalBuiltins.metal:50`). Real WPE is matrix-driven; camera center/zoom/up unrepresented.
- **Major — object quad transforms apply only for `.scene` pass targets** (`WPEMetalRenderExecutor.swift:875`). Multi-pass FBO effects render fullscreen first, transform later → changed shader-space semantics.
- **Minor — origin normalization heuristic not WPE-native** (`:899` treats 0…1 as canvas fraction; WPE origins are pixel/world).

## 3. Shader Transpile — *useful subset, not faithful backend*

- **Critical — vertex shaders effectively ignored.** `WPESwiftShaderCompiler.swift:31` compiles only the fragment path, rejects one perspective-varying case (`:101`); `WPEShaderTranspiler.swift:1959` synthesizes varyings from `in.uv`. Real WPE computes UVs/scrolls/perspective in the vertex shader.
- **Major — unsupported preprocessor expr → false (0).** `WPEShaderTranspiler.swift:336`; parser (`~:402`) lacks binary arithmetic/bitwise/shift/modulo/mul/div/ternary → combo branches silently wrong.
- **Major — texture LOD not translated.** `WPEShaderPreprocessor.swift:196` → `textureLod`, but `WPEShaderTranspiler.swift:1206` only rewrites basic `texture(...)`. Blur/downsample/mip fail.
- **Major — texture slots capped 0-3** (`:99`, dispatcher `:735`). WPE allows higher slots. Slot-fix at `:1707` correct for 0-3.
- **Minor — `main()` detection fragile** (`:584` first `"void main"` substring).
- **Minor — `gl_FragCoord` detected but not implemented** (`:113` presence flag; no usable MSL alias).

## Recommendation (codex)

Prioritize **Stage 2 (coordinates)** — Y-axis + transform inconsistencies produce convincing-but-wrong output across many wallpapers. **Stage 3** should fail-closed / fallback when vertex shaders, unsupported `#if`, LOD calls, or slots ≥4 are present. **Stage 1** is closest to real WPE but needs TEXS subrect/affine, mipmaps, puppet skinning.

Action items: golden visual probes for off-center/rotated/parallax; one authoritative coordinate convention for all paths; consistent TEXS subrect/affine; mip chains + sRGB/linear intent; shader capability classification → fallback; treat MDL skinning as unsupported until a real bone path exists.
