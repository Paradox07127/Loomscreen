# WPE Phase 2D-C Pre-Compiled MSL Effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pragmatic pre-compiled MSL built-in effect set for common WPE post-processing shaders so Phase 2C’s Metal executor can render meaningful approximations for color balance, blur, vignette, water/distort, and shake effects without GLSL translation.

**Architecture:** Phase 2D-C extends the existing Phase 2C built-in shader path: `WPERenderPipelineBuilder` recognizes selected WPE effect aliases as built-ins, and `WPEMetalRenderExecutor` dispatches normalized effect names to hand-written MSL fragments in `WPEMetalBuiltins.metal`. Unsupported Workshop shaders still fail closed with `unsupportedShader`; there is no auto-translation, no SPIRV-Cross, and no new rendering path.

**Tech Stack:** Swift 6 strict concurrency, Foundation, Metal, MetalKit, MSL built-in shader library, Swift Testing, `xcodebuild`.

---

## Suitability Assessment

Phase 2D-C is a good fit for the current codebase because Phase 2A, 2A holdovers, 2B, 2C, and 2E are merged on `origin/main` at `fd56027`:

- `WPEMetalRenderExecutor` already has the Phase 2C dispatch table, target routing, blend/depth-aware pipeline cache, `normalizedBuiltinShaderName`, `renderPipeline(fragmentName:blendMode:colorPixelFormat:depthPixelFormat:)`, and `colorVector(for:)`.
- `WPERenderPipelineBuilder` already recognizes selected built-ins before trying to load `shaders/*.vert` and `shaders/*.frag`, so effect aliases can be added without touching parser or graph-builder IR.
- `WPEPreparedRenderPass.uniformValues` already carries annotation defaults, pass overrides, and Phase 2B/2E runtime uniforms such as `g_Time`.
- `pass.pass.constants` preserves original effect override constants, which matters for constants whose names might collide with runtime uniforms.
- `WPEMetalBuiltins.metal` already compiles a fullscreen vertex and built-in fragments against `WPEVertexOut { float4 position; float2 uv; }`.
- `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift` already has Metal-gated golden pixel helpers using `#require(MTLCreateSystemDefaultDevice())`.
- There is no `.context/` directory on `origin/main`, so no `.context/prefs/coding-style.md`, `.context/prefs/workflow.md`, or `.context/history/commits.jsonl` constraints apply.

The effect set is intentionally five effects to satisfy the requested 4-6 task structure while covering the highest-value categories:

1. `effects/colorbalance` for brightness/contrast/saturation.
2. `effects/blur` for a single-pass 9-tap blur.
3. `effects/vignette` for radial darkening.
4. `effects/water` plus `effects/distort` aliases for sin-based UV displacement.
5. `effects/shake` for deterministic bounded UV jitter.

Deferred from this slice: grain and chromatic aberration. Grain needs stable noise semantics to avoid adding visual dirt to scenes that only wanted subtle film grain; chromatic aberration is useful but lower frequency than the selected set. Both remain good follow-ups under the same dispatch pattern.

---

## Architecture Decision

### Rationale

Use the pragmatic “C” route from the Phase 2 roadmap:

- Add hand-written MSL fragments for selected common WPE effects.
- Register each effect through the same normalized built-in shader name path used by Phase 2C util shaders.
- Bind one source texture plus one small per-effect uniform struct.
- Source scalar uniforms from `WPEPreparedRenderPass.uniformValues` first, then `pass.pass.constants`, matching the existing `colorVector(for:)` fallback pattern.
- Keep unsupported shaders fail-closed so Phase 2A H1 diagnostics still flag unsupported layers instead of hiding failures behind weak approximations.

### Rejected Alternatives

- **Full GLSL to MSL translation:** rejected for Phase 2D-C because it is much larger, higher risk, and unnecessary for the selected common effects.
- **SPIRV-Cross pipeline:** deferred to a broader shader-compatibility phase; it would introduce toolchain and asset-processing complexity outside this pragmatic slice.
- **Generic parameter table:** rejected in favor of per-effect Swift/MSL structs. Small typed structs are easier to validate against `setFragmentBytes(...)`, preserve Metal alignment, and keep each dispatch case readable.
- **Multi-pass separable blur:** deferred. Phase 2D-C uses one horizontal 9-tap pass; full two-pass blur belongs in a later quality pass.
- **UI/capability classifier changes:** rejected. Phase 2E behavior and existing diagnostics stay unchanged.

### Dispatch Extension

Both `WPERenderPipelineBuilder` and `WPEMetalRenderExecutor` should normalize the same aliases to these designated names:

- `effect_colorbalance`
- `effect_blur`
- `effect_vignette`
- `effect_water`
- `effect_shake`

Alias rules:

- Strip a trailing `.json`.
- Strip one leading `materials/` prefix.
- Accept direct leaf aliases such as `water`.
- Accept `effects/<family>`.
- Accept `effects/<family>/<family>`.
- Treat `effects/distort`, `effects/distort/distort`, and `distort` as `effect_water`.

Examples:

- `effects/water/water.json` → `effect_water`
- `materials/effects/water/water` → `effect_water`
- `effects/distort` → `effect_water`
- `effects/blur/blur.json` → `effect_blur`
- `colorbalance` → `effect_colorbalance`

### Uniform Struct Strategy

Use one Swift struct and one MSL struct per effect:

- `WPEColorBalanceUniforms`: `brightness`, `contrast`, `saturation`, padding.
- `WPEBlurUniforms`: `texelSize`, `radius`, padding.
- `WPEVignetteUniforms`: `innerRadius`, `outerRadius`, `intensity`, padding.
- `WPEWaterUniforms`: `amplitude`, `frequency`, `speed`, `time`.
- `WPEShakeUniforms`: `magnitude`, `time`, `frequency`, padding.

All structs are 16-byte stride-friendly and are bound at fragment buffer index `0`. The source texture is bound at texture index `0`.

### Assumptions

- Canonical scalar names are `u_Brightness`, `u_Contrast`, `u_Saturation`, `u_Radius`, `u_InnerRadius`, `u_OuterRadius`, `u_Intensity`, `u_Amplitude`, `u_Frequency`, `u_Speed`, and `u_Magnitude`.
- Small alias arrays can be used in dispatch to tolerate common lowercase/material-style names such as `brightness`, `contrast`, `saturation`, `radius`, `amount`, and `strength`.
- `g_Time` continues to come from Phase 2B runtime uniforms after `addingMetalRuntimeUniforms(...)`.
- Source textures remain texture binding `0`, falling back to `pass.pass.textures[0]` and then `pass.pass.source`.

### Potential Side Effects

- More Workshop scenes render instead of failing closed, but the output is approximate, not WPE pixel parity.
- Alias recognition may cause a scene shader named only `water`, `blur`, or `shake` to use a built-in approximation even if the Workshop author supplied a custom shader with the same leaf name.
- The single-pass blur is visibly cheaper and less isotropic than real WPE multi-pass blur.
- Water/distort aliases share one approximation; custom distortion masks remain unsupported.

---

## Scope

### In Scope

- Five pre-compiled MSL effect fragments:
  - Color balance.
  - 9-tap blur.
  - Vignette.
  - Water/distort UV displacement.
  - Shake UV jitter.
- Per-effect Swift and MSL uniform structs.
- Builder alias recognition for the selected effect families.
- Executor dispatch cases using Phase 2C’s render pipeline cache and texture resolution.
- Scalar constant lookup helper:
  - `floatScalar(named:in:default:)`
  - small multi-name wrapper for practical aliases.
- One golden-pixel Metal test per effect with known input bytes, known uniforms, and expected output bytes.
- Alias tests proving builder built-in recognition does not read shader files.
- Existing unsupported shader behavior remains intact.

### Out Of Scope

- GLSL translation.
- SPIRV-Cross.
- Multi-pass blur.
- Compute shaders.
- Audio uniforms.
- Particle systems.
- HTML/JS scenes.
- Capability classifier changes.
- UI changes, including `WPESceneDetailView`.
- New third-party dependencies.
- Pixel parity with Wallpaper Engine.

---

## File Structure

### New Files

- None.

### Existing Files To Modify

- `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Add five Swift uniform structs.
  - Add scalar lookup helpers.
  - Extend `normalizedBuiltinShaderName`.
  - Add effect dispatch cases to `WPEMetalResolvedShaderInputs.dispatch(...)`.

- `LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift`
  - Extend built-in alias recognition.
  - Return a built-in marker program for effect aliases without loading shader files.

- `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
  - Add five MSL uniform structs.
  - Add five MSL fragment functions.

### Test Files

- `LiveWallpaperTests/WPERenderPipelineBuilderTests.swift`
  - Add alias recognition test for effect built-ins.

- `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
  - Add shared effect-pass helper.
  - Add approximate pixel assertion helper.
  - Add five golden-pixel tests.

---

## Task 1: Shader Name Normalization And Dispatch Infrastructure

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift`
- Test: `LiveWallpaperTests/WPERenderPipelineBuilderTests.swift`

- [ ] **Step 1: Write the failing builder alias test**

Append this test inside `WPERenderPipelineBuilderTests`.

~~~swift
@Test("Treats precompiled WPE effect aliases as builtins")
func treatsPrecompiledEffectAliasesAsBuiltins() throws {
    let fixture = try makeFixture(files: [:])
    defer { fixture.cleanup() }

    let aliases: [(shader: String, expectedName: String)] = [
        ("effects/colorbalance/colorbalance.json", "effects/colorbalance/colorbalance.json"),
        ("materials/effects/blur/blur", "materials/effects/blur/blur"),
        ("effects/vignette", "effects/vignette"),
        ("water", "water"),
        ("effects/distort/distort.json", "effects/distort/distort.json"),
        ("effects/shake/shake", "effects/shake/shake")
    ]

    for alias in aliases {
        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "\(alias.shader)/effect.json"),
                        shader: alias.shader,
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == alias.expectedName)
        #expect(shader.isBuiltin)
    }
}
~~~

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests/treatsPrecompiledEffectAliasesAsBuiltins
~~~

Expected: FAIL with `WPERenderPipelineError.shaderMissing(...)`.

- [ ] **Step 2: Add shared normalization helpers to `WPERenderPipelineBuilder.swift`**

Inside `WPEShaderSourceLoader`, replace the existing `normalizedBuiltinShaderName(_:)` with this version and add `isEffectAlias`.

~~~swift
private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
    let lower = shaderName.lowercased()
    let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
    let canonical = withoutJSON.hasPrefix("materials/")
        ? String(withoutJSON.dropFirst("materials/".count))
        : withoutJSON

    switch canonical {
    case "solidcolor":
        return "solidcolor"
    case "solidlayer", "util/solidlayer", "models/util/solidlayer":
        return "solidlayer"
    case "copy", "commands/copy", "util/copy":
        return "copy"
    case "compose", "util/compose":
        return "compose"
    default:
        if isEffectAlias(canonical, family: "colorbalance") {
            return "effect_colorbalance"
        }
        if isEffectAlias(canonical, family: "blur") {
            return "effect_blur"
        }
        if isEffectAlias(canonical, family: "vignette") {
            return "effect_vignette"
        }
        if isEffectAlias(canonical, family: "water")
            || isEffectAlias(canonical, family: "distort") {
            return "effect_water"
        }
        if isEffectAlias(canonical, family: "shake") {
            return "effect_shake"
        }
        return withoutJSON
    }
}

private func isEffectAlias(_ shaderName: String, family: String) -> Bool {
    shaderName == family
        || shaderName == "effects/\(family)"
        || shaderName == "effects/\(family)/\(family)"
}
~~~

- [ ] **Step 3: Return built-in marker programs for effects**

In `builtinProgram(shaderName:combos:)`, add these cases before `default`.

~~~swift
case "effect_colorbalance",
     "effect_blur",
     "effect_vignette",
     "effect_water",
     "effect_shake":
    return effectProgram(shaderName: shaderName, combos: combos)
~~~

Add this helper near the existing `copyProgram`.

~~~swift
private func effectProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
    let vertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;

    void main() {
        gl_Position = vec4(a_Position, 1.0);
        v_TexCoord = a_TexCoord;
    }
    """
    let fragment = """
    uniform sampler2D g_Texture0;
    varying vec2 v_TexCoord;

    void main() {
        gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
    }
    """
    return WPEShaderProgram(
        name: shaderName,
        vertexSource: shaderPrelude(comboValues: combos, stage: .vertex) + vertex,
        fragmentSource: shaderPrelude(comboValues: combos, stage: .fragment) + fragment.replacingOccurrences(
            of: "gl_FragColor",
            with: "out_FragColor"
        ),
        isBuiltin: true
    )
}
~~~

- [ ] **Step 4: Add the same normalization to `WPEMetalRenderExecutor.swift`**

Replace the executor’s `normalizedBuiltinShaderName(_:)` with this version and add `isEffectAlias`.

~~~swift
fileprivate func normalizedBuiltinShaderName(_ shaderName: String) -> String {
    let lower = shaderName.lowercased()
    let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
    let canonical = withoutJSON.hasPrefix("materials/")
        ? String(withoutJSON.dropFirst("materials/".count))
        : withoutJSON

    switch canonical {
    case "solidcolor":
        return "solidcolor"
    case "solidlayer", "util/solidlayer", "models/util/solidlayer":
        return "solidlayer"
    case "copy", "commands/copy", "util/copy":
        return "copy"
    case "compose", "util/compose":
        return "compose"
    default:
        if isEffectAlias(canonical, family: "colorbalance") {
            return "effect_colorbalance"
        }
        if isEffectAlias(canonical, family: "blur") {
            return "effect_blur"
        }
        if isEffectAlias(canonical, family: "vignette") {
            return "effect_vignette"
        }
        if isEffectAlias(canonical, family: "water")
            || isEffectAlias(canonical, family: "distort") {
            return "effect_water"
        }
        if isEffectAlias(canonical, family: "shake") {
            return "effect_shake"
        }
        if withoutJSON.hasPrefix("genericimage") {
            return "copy"
        }
        return withoutJSON
    }
}

private func isEffectAlias(_ shaderName: String, family: String) -> Bool {
    shaderName == family
        || shaderName == "effects/\(family)"
        || shaderName == "effects/\(family)/\(family)"
}
~~~

- [ ] **Step 5: Add scalar uniform lookup helpers**

Add these methods inside `WPEMetalRenderExecutor`, near `colorVector(for:)`.

~~~swift
fileprivate func floatScalar(
    named name: String,
    in pass: WPEPreparedRenderPass,
    default defaultValue: Float
) -> Float {
    scalarFloat(pass.uniformValues[name])
        ?? scalarFloat(pass.pass.constants[name])
        ?? defaultValue
}

fileprivate func floatScalar(
    named names: [String],
    in pass: WPEPreparedRenderPass,
    default defaultValue: Float
) -> Float {
    for name in names {
        if let value = scalarFloat(pass.uniformValues[name])
            ?? scalarFloat(pass.pass.constants[name]) {
            return value
        }
    }
    return defaultValue
}

private func scalarFloat(_ value: WPESceneShaderConstantValue?) -> Float? {
    switch value {
    case .number(let number):
        return Float(number)
    case .vector(let vector):
        return vector.first.map(Float.init)
    case .bool(let bool):
        return bool ? 1 : 0
    case .string(let string):
        return Float(string)
    case nil:
        return nil
    }
}
~~~

- [ ] **Step 6: Run the alias test**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests/treatsPrecompiledEffectAliasesAsBuiltins
~~~

Expected: PASS.

---

## Task 2: Color Balance Effect

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write the failing golden-pixel test**

Add this helper near the Phase 2C test helpers.

~~~swift
private func effectPass(
    id: String,
    shader: String,
    source: WPETextureReference,
    target: WPERenderTarget = .scene,
    constants: [String: WPESceneShaderConstantValue],
    blending: String = "disabled"
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .effect(file: "\(shader)/effect.json"),
        shader: shader,
        source: source,
        target: target,
        textures: [0: source],
        binds: [:],
        constants: constants,
        combos: [:],
        blending: blending,
        cullMode: "nocull",
        depthTest: "disabled",
        depthWrite: "disabled"
    )
}

private func expectPixel(
    _ pixel: Pixel,
    approximately expected: Pixel,
    tolerance: Int = 2
) {
    #expect(abs(Int(pixel.r) - Int(expected.r)) <= tolerance)
    #expect(abs(Int(pixel.g) - Int(expected.g)) <= tolerance)
    #expect(abs(Int(pixel.b) - Int(expected.b)) <= tolerance)
    #expect(abs(Int(pixel.a) - Int(expected.a)) <= tolerance)
}
~~~

Add this test inside `WPEMetalRenderExecutorTests`.

~~~swift
@Test("Color balance built-in desaturates red to luminance")
func colorBalanceDesaturatesRedToLuminance() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)
    let input = try makeRGBAInputTexture(
        device: device,
        width: 1,
        height: 1,
        bytes: Data([255, 0, 0, 255])
    )

    let pass = effectPass(
        id: "effect.colorbalance",
        shader: "effects/colorbalance",
        source: .image("materials/red.png"),
        constants: [
            "u_Brightness": .number(0),
            "u_Contrast": .number(1),
            "u_Saturation": .number(0)
        ]
    )
    let pipeline = preparedPipeline(
        localFBOs: [],
        passes: [
            preparedBuiltinPass(
                pass,
                bindings: [0: .image("materials/red.png")],
                uniforms: pass.constants
            )
        ]
    )

    let output = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 1, height: 1),
        textures: ["materials/red.png": input]
    )
    let pixel = try readPixel(output, x: 0, y: 0)

    // Linear luma for red is 0.2126; storing to rgba8Unorm_srgb reads back ~127.
    expectPixel(pixel, approximately: Pixel(r: 127, g: 127, b: 127, a: 255))
}
~~~

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/colorBalanceDesaturatesRedToLuminance
~~~

Expected: FAIL with `unsupportedShader("effects/colorbalance")` or `pipelineUnavailable("wpe_effect_colorbalance_fragment")`.

- [ ] **Step 2: Add the exact Swift uniform struct**

Add near `WPECopyUniforms`.

~~~swift
struct WPEColorBalanceUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var padding: Float = 0
}
~~~

- [ ] **Step 3: Add the exact MSL struct and fragment**

Append to `WPEMetalBuiltins.metal`.

~~~metal
struct WPEColorBalanceUniforms {
    float brightness;
    float contrast;
    float saturation;
    float padding;
};

fragment half4 wpe_effect_colorbalance_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEColorBalanceUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 color = float4(texture0.sample(linearSampler, in.uv));

    float3 rgb = color.rgb + uniforms.brightness;
    rgb = (rgb - 0.5) * max(uniforms.contrast, 0.0) + 0.5;

    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, max(uniforms.saturation, 0.0));

    return half4(float4(saturate(rgb), color.a));
}
~~~

- [ ] **Step 4: Add the executor dispatch case**

In `WPEMetalResolvedShaderInputs.dispatch(...)`, add this switch case before `default`.

~~~swift
case "effect_colorbalance":
    encoder.setRenderPipelineState(try executor.renderPipeline(
        fragmentName: "wpe_effect_colorbalance_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat,
        depthPixelFormat: depthPixelFormat
    ))
    let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let texture = try executor.resolve(
        reference: reference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    encoder.setFragmentTexture(texture, index: 0)
    var uniforms = WPEColorBalanceUniforms(
        brightness: executor.floatScalar(
            named: ["u_Brightness", "brightness", "g_BrightnessOffset"],
            in: pass,
            default: 0
        ),
        contrast: executor.floatScalar(
            named: ["u_Contrast", "contrast"],
            in: pass,
            default: 1
        ),
        saturation: executor.floatScalar(
            named: ["u_Saturation", "saturation"],
            in: pass,
            default: 1
        )
    )
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEColorBalanceUniforms>.stride, index: 0)
~~~

- [ ] **Step 5: Run the color balance test**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/colorBalanceDesaturatesRedToLuminance
~~~

Expected: PASS.

---

## Task 3: Blur Effect

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write the failing golden-pixel test**

Add this test inside `WPEMetalRenderExecutorTests`.

~~~swift
@Test("Blur built-in applies centered 9 tap kernel")
func blurAppliesCenteredNineTapKernel() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)

    let input = try makeRGBAInputTexture(
        device: device,
        width: 9,
        height: 1,
        bytes: Data([
            0, 0, 0, 255,
            0, 0, 0, 255,
            0, 0, 0, 255,
            0, 0, 0, 255,
            255, 0, 0, 255,
            0, 0, 0, 255,
            0, 0, 0, 255,
            0, 0, 0, 255,
            0, 0, 0, 255
        ])
    )

    let pass = effectPass(
        id: "effect.blur",
        shader: "effects/blur",
        source: .image("materials/pulse.png"),
        constants: ["u_Radius": .number(1)]
    )
    let pipeline = preparedPipeline(
        localFBOs: [],
        passes: [
            preparedBuiltinPass(
                pass,
                bindings: [0: .image("materials/pulse.png")],
                uniforms: pass.constants
            )
        ]
    )

    let output = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 9, height: 1),
        textures: ["materials/pulse.png": input]
    )
    let pixel = try readPixel(output, x: 4, y: 0)

    // Center weight is 0.18; storing 0.18 linear red to sRGB reads back ~118.
    expectPixel(pixel, approximately: Pixel(r: 118, g: 0, b: 0, a: 255))
}
~~~

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/blurAppliesCenteredNineTapKernel
~~~

Expected: FAIL with `unsupportedShader("effects/blur")` or `pipelineUnavailable("wpe_effect_blur_fragment")`.

- [ ] **Step 2: Add the exact Swift uniform struct**

Add near the other effect uniform structs.

~~~swift
struct WPEBlurUniforms {
    var texelSize: SIMD2<Float>
    var radius: Float
    var padding: Float = 0
}
~~~

- [ ] **Step 3: Add the exact MSL struct and fragment**

Append to `WPEMetalBuiltins.metal`.

~~~metal
struct WPEBlurUniforms {
    float2 texelSize;
    float radius;
    float padding;
};

fragment half4 wpe_effect_blur_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEBlurUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    const float offsets[9] = {
        -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0
    };
    const float weights[9] = {
        0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05
    };

    float2 stepUV = float2(uniforms.texelSize.x, 0.0) * max(uniforms.radius, 0.0);
    float4 color = float4(0.0);
    for (uint i = 0; i < 9; i++) {
        float2 uv = clamp(in.uv + stepUV * offsets[i], float2(0.0), float2(1.0));
        color += float4(texture0.sample(linearSampler, uv)) * weights[i];
    }

    return half4(color);
}
~~~

- [ ] **Step 4: Add the executor dispatch case**

Add this switch case before `default`.

~~~swift
case "effect_blur":
    encoder.setRenderPipelineState(try executor.renderPipeline(
        fragmentName: "wpe_effect_blur_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat,
        depthPixelFormat: depthPixelFormat
    ))
    let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let texture = try executor.resolve(
        reference: reference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    encoder.setFragmentTexture(texture, index: 0)
    var uniforms = WPEBlurUniforms(
        texelSize: SIMD2<Float>(
            1 / Float(max(texture.width, 1)),
            1 / Float(max(texture.height, 1))
        ),
        radius: executor.floatScalar(
            named: ["u_Radius", "radius", "amount", "strength"],
            in: pass,
            default: 1
        )
    )
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlurUniforms>.stride, index: 0)
~~~

- [ ] **Step 5: Run the blur test**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/blurAppliesCenteredNineTapKernel
~~~

Expected: PASS.

---

## Task 4: Vignette Effect

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write the failing golden-pixel test**

Add this test inside `WPEMetalRenderExecutorTests`.

~~~swift
@Test("Vignette built-in darkens outside outer radius")
func vignetteDarkensOutsideOuterRadius() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)

    let input = try makeRGBAInputTexture(
        device: device,
        width: 4,
        height: 4,
        bytes: Data(repeating: 255, count: 4 * 4 * 4)
    )

    let pass = effectPass(
        id: "effect.vignette",
        shader: "effects/vignette/vignette.json",
        source: .image("materials/white.png"),
        constants: [
            "u_InnerRadius": .number(0),
            "u_OuterRadius": .number(0.5),
            "u_Intensity": .number(1)
        ]
    )
    let pipeline = preparedPipeline(
        localFBOs: [],
        passes: [
            preparedBuiltinPass(
                pass,
                bindings: [0: .image("materials/white.png")],
                uniforms: pass.constants
            )
        ]
    )

    let output = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 4, height: 4),
        textures: ["materials/white.png": input]
    )
    let pixel = try readPixel(output, x: 0, y: 0)

    expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 0, a: 255))
}
~~~

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/vignetteDarkensOutsideOuterRadius
~~~

Expected: FAIL with `unsupportedShader("effects/vignette/vignette.json")` or `pipelineUnavailable("wpe_effect_vignette_fragment")`.

- [ ] **Step 2: Add the exact Swift uniform struct**

Add near the other effect uniform structs.

~~~swift
struct WPEVignetteUniforms {
    var innerRadius: Float
    var outerRadius: Float
    var intensity: Float
    var padding: Float = 0
}
~~~

- [ ] **Step 3: Add the exact MSL struct and fragment**

Append to `WPEMetalBuiltins.metal`.

~~~metal
struct WPEVignetteUniforms {
    float innerRadius;
    float outerRadius;
    float intensity;
    float padding;
};

fragment half4 wpe_effect_vignette_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEVignetteUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    float4 color = float4(texture0.sample(linearSampler, in.uv));
    float innerRadius = max(uniforms.innerRadius, 0.0);
    float outerRadius = max(uniforms.outerRadius, innerRadius + 0.0001);
    float edge = smoothstep(innerRadius, outerRadius, distance(in.uv, float2(0.5, 0.5)));
    float factor = mix(1.0, 1.0 - saturate(uniforms.intensity), edge);

    return half4(float4(saturate(color.rgb * factor), color.a));
}
~~~

- [ ] **Step 4: Add the executor dispatch case**

Add this switch case before `default`.

~~~swift
case "effect_vignette":
    encoder.setRenderPipelineState(try executor.renderPipeline(
        fragmentName: "wpe_effect_vignette_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat,
        depthPixelFormat: depthPixelFormat
    ))
    let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let texture = try executor.resolve(
        reference: reference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    encoder.setFragmentTexture(texture, index: 0)
    var uniforms = WPEVignetteUniforms(
        innerRadius: executor.floatScalar(
            named: ["u_InnerRadius", "innerRadius", "inner"],
            in: pass,
            default: 0.35
        ),
        outerRadius: executor.floatScalar(
            named: ["u_OuterRadius", "outerRadius", "outer"],
            in: pass,
            default: 0.75
        ),
        intensity: executor.floatScalar(
            named: ["u_Intensity", "intensity", "amount", "strength"],
            in: pass,
            default: 0.5
        )
    )
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEVignetteUniforms>.stride, index: 0)
~~~

- [ ] **Step 5: Run the vignette test**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/vignetteDarkensOutsideOuterRadius
~~~

Expected: PASS.

---

## Task 5: Water And Distort Effect

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write the failing golden-pixel test**

Add this test inside `WPEMetalRenderExecutorTests`.

~~~swift
@Test("Water built-in displaces UVs with time driven wave")
func waterDisplacesUVsWithWave() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)

    let input = try makeRGBAInputTexture(
        device: device,
        width: 2,
        height: 2,
        bytes: Data([
            255, 0, 0, 255,
            255, 0, 0, 255,
            0, 0, 255, 255,
            0, 0, 255, 255
        ])
    )

    let pass = effectPass(
        id: "effect.water",
        shader: "effects/distort",
        source: .image("materials/two_rows.png"),
        constants: [
            "u_Amplitude": .number(1),
            "u_Frequency": .number(0),
            "u_Speed": .number(0)
        ]
    )
    let pipeline = preparedPipeline(
        localFBOs: [],
        passes: [
            preparedBuiltinPass(
                pass,
                bindings: [0: .image("materials/two_rows.png")],
                uniforms: pass.constants
            )
        ]
    )

    let output = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 2, height: 2),
        textures: ["materials/two_rows.png": input],
        runtimeUniforms: WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )
    )
    let pixel = try readPixel(output, x: 0, y: 0)

    expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 255, a: 255))
}
~~~

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/waterDisplacesUVsWithWave
~~~

Expected: FAIL with `unsupportedShader("effects/distort")` or `pipelineUnavailable("wpe_effect_water_fragment")`.

- [ ] **Step 2: Add the exact Swift uniform struct**

Add near the other effect uniform structs.

~~~swift
struct WPEWaterUniforms {
    var amplitude: Float
    var frequency: Float
    var speed: Float
    var time: Float
}
~~~

- [ ] **Step 3: Add the exact MSL struct and fragment**

Append to `WPEMetalBuiltins.metal`.

~~~metal
struct WPEWaterUniforms {
    float amplitude;
    float frequency;
    float speed;
    float time;
};

fragment half4 wpe_effect_water_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEWaterUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    float phase = uniforms.time * uniforms.speed;
    float frequency = max(uniforms.frequency, 0.0);
    float2 wave = float2(
        sin((in.uv.y + phase) * frequency),
        cos((in.uv.x + phase) * frequency)
    ) * uniforms.amplitude;

    float2 uv = clamp(in.uv + wave, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}
~~~

- [ ] **Step 4: Add the executor dispatch case**

Add this switch case before `default`.

~~~swift
case "effect_water":
    encoder.setRenderPipelineState(try executor.renderPipeline(
        fragmentName: "wpe_effect_water_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat,
        depthPixelFormat: depthPixelFormat
    ))
    let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let texture = try executor.resolve(
        reference: reference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    encoder.setFragmentTexture(texture, index: 0)
    var uniforms = WPEWaterUniforms(
        amplitude: executor.floatScalar(
            named: ["u_Amplitude", "amplitude", "amount", "strength"],
            in: pass,
            default: 0.01
        ),
        frequency: executor.floatScalar(
            named: ["u_Frequency", "frequency", "scale"],
            in: pass,
            default: 20
        ),
        speed: executor.floatScalar(
            named: ["u_Speed", "speed"],
            in: pass,
            default: 1
        ),
        time: executor.floatScalar(
            named: "g_Time",
            in: pass,
            default: 0
        )
    )
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEWaterUniforms>.stride, index: 0)
~~~

- [ ] **Step 5: Run the water/distort test**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/waterDisplacesUVsWithWave
~~~

Expected: PASS.

---

## Task 6: Shake Effect

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write the failing golden-pixel test**

Add this test inside `WPEMetalRenderExecutorTests`.

~~~swift
@Test("Shake built-in applies bounded deterministic UV offset")
func shakeAppliesBoundedDeterministicUVOffset() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)

    let input = try makeRGBAInputTexture(
        device: device,
        width: 4,
        height: 1,
        bytes: Data([
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255
        ])
    )

    let pass = effectPass(
        id: "effect.shake",
        shader: "effects/shake/shake.json",
        source: .image("materials/stripe.png"),
        constants: [
            "u_Magnitude": .number(0.25),
            "u_Frequency": .number(1)
        ]
    )
    let pipeline = preparedPipeline(
        localFBOs: [],
        passes: [
            preparedBuiltinPass(
                pass,
                bindings: [0: .image("materials/stripe.png")],
                uniforms: pass.constants
            )
        ]
    )

    let output = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 4, height: 1),
        textures: ["materials/stripe.png": input],
        runtimeUniforms: WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )
    )
    let pixel = try readPixel(output, x: 1, y: 0)

    // At time 0, jitter is +0.25 in X, so output pixel x=1 samples source x=2.
    expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 255, a: 255))
}
~~~

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/shakeAppliesBoundedDeterministicUVOffset
~~~

Expected: FAIL with `unsupportedShader("effects/shake/shake.json")` or `pipelineUnavailable("wpe_effect_shake_fragment")`.

- [ ] **Step 2: Add the exact Swift uniform struct**

Add near the other effect uniform structs.

~~~swift
struct WPEShakeUniforms {
    var magnitude: Float
    var time: Float
    var frequency: Float
    var padding: Float = 0
}
~~~

- [ ] **Step 3: Add the exact MSL struct and fragment**

Append to `WPEMetalBuiltins.metal`.

~~~metal
struct WPEShakeUniforms {
    float magnitude;
    float time;
    float frequency;
    float padding;
};

fragment half4 wpe_effect_shake_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEShakeUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    float frequency = max(uniforms.frequency, 0.001);
    float phase = floor(uniforms.time * frequency);
    float magnitude = clamp(uniforms.magnitude, 0.0, 0.25);
    float2 jitter = float2(
        cos(phase * 12.9898),
        sin(phase * 78.233)
    ) * magnitude;

    float2 uv = clamp(in.uv + jitter, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}
~~~

- [ ] **Step 4: Add the executor dispatch case**

Add this switch case before `default`.

~~~swift
case "effect_shake":
    encoder.setRenderPipelineState(try executor.renderPipeline(
        fragmentName: "wpe_effect_shake_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat,
        depthPixelFormat: depthPixelFormat
    ))
    let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let texture = try executor.resolve(
        reference: reference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    encoder.setFragmentTexture(texture, index: 0)
    var uniforms = WPEShakeUniforms(
        magnitude: executor.floatScalar(
            named: ["u_Magnitude", "magnitude", "amount", "strength"],
            in: pass,
            default: 0.01
        ),
        time: executor.floatScalar(
            named: "g_Time",
            in: pass,
            default: 0
        ),
        frequency: executor.floatScalar(
            named: ["u_Frequency", "frequency", "speed"],
            in: pass,
            default: 24
        )
    )
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEShakeUniforms>.stride, index: 0)
~~~

- [ ] **Step 5: Run the shake test**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests/shakeAppliesBoundedDeterministicUVOffset
~~~

Expected: PASS.

---

## Final Verification

Run the focused suites first:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests
~~~

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Then run the full regression suite to protect the existing Phase 2A/2B/2C/2E surface:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO
~~~

Expected final state:

- Existing 410 Phase 2A/2B/2C/2E tests still pass.
- New builder alias test passes.
- Five new golden-pixel effect tests pass with ±2 LSB tolerance.
- Existing `rejectsCustomShader` behavior still throws `unsupportedShader` for unknown shader names.
- No files under `LiveWallpaper/Views/` are modified.

---

## Main Improvements

- Common WPE post-processing effects render as visible approximations instead of black frames.
- Phase 2C’s explicit built-in dispatch model remains intact and fail-closed.
- Runtime `g_Time` now drives precompiled water and shake effects without adding audio or custom shader translation.
- Per-effect uniform structs keep Metal buffer layout simple and testable.
- `effects/distort` scenes get a practical water-style displacement fallback through alias normalization.
- The implementation path is incremental: each effect can be merged and verified independently.

---

## Self-Review

### Spec Coverage

- Pre-compiled MSL fragments: covered in Tasks 2-6.
- Per-effect Swift uniform structs: covered in Tasks 2-6.
- Builder alias recognition: covered in Task 1.
- Executor dispatch table: covered in Tasks 2-6.
- Scalar constant lookup helper: covered in Task 1.
- Golden-pixel tests: covered in Tasks 2-6.
- No auto-translation: preserved by built-in-only alias recognition and existing `unsupportedShader` default.
- No UI changes: explicitly excluded and no `Views/` files are touched.
- No new dependencies: all changes use Foundation/Metal/MetalKit/Swift Testing already present.

### Type Consistency

- Swift and MSL struct field order matches for every effect.
- Every `setFragmentBytes(...)` length uses the matching Swift `MemoryLayout<...>.stride`.
- Every dispatch case calls `renderPipeline(fragmentName:blendMode:colorPixelFormat:depthPixelFormat:)` with the destination pixel format and current depth pixel format.
- Every effect binds source texture index `0` and uniform buffer index `0`.

### Deferred Work

- Grain effect is deferred to a follow-up because a convincing implementation needs stable noise semantics.
- Chromatic aberration is deferred because it is lower value than the selected five effects.
- Full separable two-pass blur is deferred to a later quality/performance phase.
- Real Workshop shader parity remains deferred to the broader Phase 2D A/B routes.
