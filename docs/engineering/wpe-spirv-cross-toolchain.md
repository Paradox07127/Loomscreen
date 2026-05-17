# WPE Shader Toolchain — Phase 2 (SPIRV-Cross + glslang)

**Status:** planning. Branch `claude/wpe-spirv-cross-toolchain`. No code yet — this
PR only adds the plan doc so the integration target lives in tree before Phase 2a
starts.

**Goal:** replace the hand-written `WPEShaderTranspiler` Swift translator with a
glslang → SPIR-V → SPIRV-Cross MSL pipeline so the WPE corpus's "custom shader"
scenes compile out of the box. This is the unlock the Phase A.3 corpus log
flagged — 29 transpiler failures, every one of them on shaders the Swift-pure
translator can't physically cover (helper uniforms, multi-pass FBO chains,
gl_FragCoord math, anything beyond the canonical single-pass effect).

## Existing seam

```
WPEMetalRenderExecutor.init(device:, shaderCompiler:)
    └─ shaderCompiler ?? WPESwiftShaderCompiler(device:)   ← today
                       ?? WPESPIRVShaderCompiler(device:)  ← Phase 2 swap
```

`WPEShaderCompiling` is already a `Sendable` protocol with a single
`compile(_:)` entry. Request: preprocessed GLSL pair + combo / texture binding
metadata. Result: `MTLLibrary` + function names + uniform layout + sampler
order. Phase 2 changes nothing outside that protocol — every caller, dispatcher
path, cache key already routes through it.

See:
- [WPEShaderCompiler.swift](../../LiveWallpaper/Runtime/WPEShaderCompiler.swift)
  — protocol + stub.
- [WPESwiftShaderCompiler.swift](../../LiveWallpaper/Runtime/WPESwiftShaderCompiler.swift)
  — current 80% Swift implementation. Stays in tree as the fallback when the
  SPIRV-Cross compile rejects exotic input (helps the corpus harness diff
  "transpiler regression" vs. "SPIRV-Cross regression").

## Vendor strategy

XCFramework, not source tree. The C++ build of glslang + SPIRV-Cross is
~30 KLOC, has its own CMake-driven generator step (`build_info.h.tmpl`),
and pulls in `<filesystem>` / `<thread>` headers that the Swift Package
Manager build phase doesn't tolerate cleanly. Pre-building an XCFramework
keeps the Xcode target dependency tree small and avoids reshipping the C++
build environment on every clone.

### Sources

- `KhronosGroup/SPIRV-Cross` — pinned tag (latest stable per [SPIRV-Cross
  releases](https://github.com/KhronosGroup/SPIRV-Cross/releases)). MIT-licensed.
- `KhronosGroup/glslang` — pinned tag. BSD-3-Clause.
- `KhronosGroup/SPIRV-Tools` (transitive of glslang for `-O`/validation).
  Apache-2.0.

All three licenses are App Store-safe; record them in
`docs/legal/third-party-licenses.md` alongside the existing notices.

### Build pipeline

Script lives at `Scripts/build_spirv_cross_xcframework.sh`. Idempotent:

1. Clone (or `git pull` if already present) each repo into
   `ThirdParty/sources/{glslang,SPIRV-Cross,SPIRV-Tools}` at the pinned tag.
2. Build static libs for `arm64-macos` only. Artifact is arm64-only **by
   design** — LiveWallpaper is Apple Silicon-only (macOS 14+), and there are
   no plans to add an x86_64 slice. `scripts/build_spirv_cross_xcframework.sh`
   correspondingly hard-codes `arm64` and should not be parameterized.
3. Lipo the static libs into one `.framework` per slice with a hand-written
   `module.modulemap` that exposes only the C entry points we wrap (no full
   C++ headers reach Swift).
4. `xcodebuild -create-xcframework` → `ThirdParty/WPEShaderToolchain.xcframework`.
5. Generate `ThirdParty/WPEShaderToolchain.xcframework.checksum` (SHA-256 of
   the framework + a hash of the pinned tags) so PR diff review can see if
   the toolchain changed.

The script is human-run, not CI-run. We do **not** want a from-source compile
on every PR build. The script is for refreshing the framework when we bump
pinned tags; the binary artifact itself is checked into git LFS (size budget
~40–80 MB for `arm64` + dSYM).

### CI guard

Add `Scripts/release_candidate_check.sh` step:

- If `WPEShaderToolchain.xcframework` mtime changed in the PR diff, fail
  unless the PR description contains the literal token
  `[xcframework-rebuild-approved]`. Prevents accidental binary churn.
- Verify the embedded checksum file matches the framework bytes.

## Swift wrapper layer

Single Swift file: `LiveWallpaper/Runtime/WPESPIRVShaderCompiler.swift`.
Wraps two C entry points exposed by the XCFramework:

```c
// glslang side
int wpe_glslang_compile_to_spirv(
    const char *vertex_glsl,
    const char *fragment_glsl,
    const uint32_t **out_spirv_words,
    size_t *out_spirv_count,
    char **out_diagnostics  // caller frees
);

// SPIRV-Cross side
int wpe_spirv_cross_translate_to_msl(
    const uint32_t *spirv_words,
    size_t spirv_count,
    char **out_msl,         // caller frees
    char **out_diagnostics  // caller frees
);
```

Memory ownership: every `char**` returned from C is heap-allocated with
`malloc`, freed by the Swift wrapper via `free`. No retain cycles, no
ARC weirdness.

The wrapper:
1. Feeds `request.processedVertexSource` / `processedFragmentSource` to
   `wpe_glslang_compile_to_spirv`. On failure → `.glslPreprocessFailed(msg)`.
2. Feeds the SPIR-V to `wpe_spirv_cross_translate_to_msl`. On failure →
   `.translationFailed(msg)`.
3. Hands the MSL string to `device.makeLibrary(source:options:)` exactly
   like `WPESwiftShaderCompiler` does today.
4. Reflects uniform layout + texture binding indices off the SPIR-V module
   (SPIRV-Cross exposes a reflection API — we want it because the runtime
   uniform packer needs the float4-slot map).

## Rollout / fallback

The renderer init seam becomes:

```swift
init(device:, shaderCompiler: WPEShaderCompiling? = nil) {
    if let injected = shaderCompiler {
        self.shaderCompiler = injected
    } else if WPESPIRVShaderCompiler.isToolchainAvailable() {
        self.shaderCompiler = WPESPIRVShaderCompiler(
            device: device,
            fallback: WPESwiftShaderCompiler(device: device)
        )
    } else {
        self.shaderCompiler = WPESwiftShaderCompiler(device: device)
    }
}
```

`WPESPIRVShaderCompiler` internally tries SPIRV-Cross first; on
`.translationFailed`, falls through to the Swift translator. That gives a
clean A/B for the corpus harness — when something regresses we can flip the
order with one Bool and see if it's our shim or the new backend.

## Test plan

- Existing `WPEShaderTranspilerTests` stays — it tests the Swift fallback.
- New `WPESPIRVShaderCompilerTests`:
  - Fixture: 6 representative corpus shaders (1 simple, 1 with helpers,
    1 multi-pass, 1 with `gl_FragCoord`, 1 audio bars, 1 video sampler).
  - For each: `compile(_:)` returns non-empty `MTLLibrary`, expected
    fragment function name, expected uniform slot count.
  - `compile(_:)` on bad GLSL surfaces `.glslPreprocessFailed` with the
    glslang diagnostic intact (regex-match the line number).
- Re-run Phase A.3 corpus harness, diff `success_count` vs. Phase 1.5
  baseline. Expected gain: 29 transpiler failures → ~3–5 (the remaining
  ones being genuine multi-pass effects that need pass-graph work, not
  shader translation).

## Risk register

| Risk | Mitigation |
|------|------------|
| Binary size — `.xcframework` adds 40–80 MB to repo | git-lfs. If hard cap matters, ship arm64-only and skip dSYM in non-release builds. |
| SPIRV-Cross emits MSL that Metal rejects (uncommon, but happens with edge bindings) | Wrapper always logs the rejected MSL via `mslLibraryFailed`. Corpus harness picks it up. |
| GLSL extension mismatch — WPE shaders sometimes use `#version 130` legacy syntax | glslang has `--client opengl100`/`--target-env opengl` modes. Pick one in the wrapper; document in this file. |
| License obligations (attribution) | App's "Acknowledgements" panel lists the three Khronos licenses verbatim. Already a convention in this repo via `docs/legal/`. |
| Toolchain update churn | XCFramework rebuild is gated by `[xcframework-rebuild-approved]` token. Manual, infrequent. |

## Sequencing

1. ✅ **Phase 2 plan** (this doc).
2. ⬜ **Phase 2a — script + checksum**: `Scripts/build_spirv_cross_xcframework.sh`
   produces a working framework on the developer's machine. PR adds the
   script + the binary artifact (LFS) + license disclosure.
3. ⬜ **Phase 2b — Swift wrapper**: `WPESPIRVShaderCompiler.swift` + 6-fixture
   test suite. Renderer init seam swapped behind `isToolchainAvailable()`
   guard so a broken framework never blocks the existing pipeline.
4. ⬜ **Phase 2c — corpus regression**: re-run the harness, file failures
   that now reveal multi-pass / pass-graph gaps. Plan Phase 3 (pass graph
   rewrite) off the new failure set.

Each sub-phase is one PR. Phase 2a is large because of the binary artifact;
Phase 2b and 2c are reviewable in normal-sized diffs.

## Open questions (resolve before Phase 2a starts)

- **Pin policy** — track SPIRV-Cross `main` or pin to a tagged release? Lean
  toward tagged release for reproducibility; revisit if upstream fixes a
  WPE-relevant bug we can't wait for.
- **Bitcode** — Apple deprecated bitcode in 2023; XCFramework can ship
  without it. Confirm no enterprise consumer cares.
- **glslang vs. shaderc** — shaderc bundles glslang + SPIRV-Tools with a
  nicer API. Decide before Phase 2a. Lean glslang because shaderc adds
  another dep tree and we don't need its niceties for a single-call site.
