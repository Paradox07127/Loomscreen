# WPE Phase 2C Multi-Pass Render Graph Executor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the real WPE multi-pass FBO/effect pipeline in the experimental Metal renderer, including target routing, pooled FBOs, `previous`/`fbo:` source resolution, WPE render states, and built-in `materials/util/` helpers.

**Architecture:** Phase 2C keeps the renderer boundary unchanged and concentrates the work inside `WPEMetalRenderExecutor`. Each render creates a frame-local target state, while allocations live in a reusable Metal target pool keyed by logical render target identity. Built-in shaders remain fail-closed and explicit; custom GLSL remains deferred to Phase 2D.

**Tech Stack:** Swift 6 strict concurrency, Foundation, CoreGraphics, Metal, MetalKit, MSL built-in shader library, Swift Testing, `xcodebuild`.

---

## Suitability Assessment

Phase 2C is now executable because Phase 2A, the Phase 2A holdovers, and Phase 2B are merged on `main`:

- `WPERenderGraph` already preserves `WPERenderTarget.scene`, `.fbo(name)`, and `.layerComposite(name)`, so executor routing can be implemented without changing parser IR.
- `WPERenderLayer.localFBOs` already carries `WPERenderFBO { name, scale, format, unique }`, so allocation can be based on graph-declared resources instead of inferring names from shader strings.
- `WPERenderPipelineBuilder` already resolves built-in shader programs, texture bindings, constants, and combo metadata, so Phase 2C can keep dispatch decisions on `pass.pass.shader`.
- `WPEMetalRenderExecutor` already renders offscreen into an sRGB output texture and has tested solidcolor/copy paths for `.scene`; Phase 2C extends that executor instead of introducing a second rendering path.
- `WPEMetalSceneRenderer.performLoad` already calls `executor.render(...)` once and caches the output texture; the render call remains synchronous from the renderer's `@MainActor` load path.
- Swift Testing fixtures already use `#require(MTLCreateSystemDefaultDevice())`, so Metal-dependent tests skip on CI hosts without Metal.
- There is no `.context/` directory in the current checkout, so no `.context/prefs/coding-style.md`, `.context/prefs/workflow.md`, or `.context/history/commits.jsonl` constraints apply.

---

## Architecture Decision

### Rationale

Phase 2C adds a frame graph execution layer inside `WPEMetalRenderExecutor`:

- **Frame-local state** tracks the most recent texture written to each logical target during one `render(...)` call.
- **Persistent target pool** owns reusable FBO/layer-composite textures across frames and releases them on `.suspended`.
- **Pipeline cache** is keyed by `(fragmentName, blendMode, colorPixelFormat)` so normal/additive/multiply variants do not rebuild per pass and do not share incompatible blend descriptors.
- **`previous` semantics** are target-local: `.previous` resolves to the latest write to the current pass target. When the pass writes the same logical target it reads, the pool returns an alternate physical texture so Metal never samples from and renders into the same texture in one encoder.
- **Built-in util shaders** are explicit aliases for WPE helper materials. The executor still rejects custom GLSL until Phase 2D.

### MTLHeap vs. Fallback

Use `MTLHeap` per pooled texture allocation when feasible:

- Build the texture descriptor from `(name, sceneRenderSize, scale, format)`.
- Call `device.heapTextureSizeAndAlign(descriptor:)`.
- If `size > 0`, create a heap large enough for the aligned texture and allocate the texture from that heap.
- If the alignment size is `0`, heap creation fails, or `heap.makeTexture(descriptor:)` returns nil, fall back to `device.makeTexture(descriptor:)`.

This keeps the code portable across Metal devices while still preferring heap-backed resources. The heap object must be retained next to the texture; otherwise the allocation backing may be released while the texture is still in the pool.

### Pipeline Cache Shape

Replace `pipelines: [String: MTLRenderPipelineState]` with:

~~~swift
private struct WPEMetalPipelineKey: Hashable {
    let fragmentName: String
    let blendMode: String
    let colorPixelFormat: MTLPixelFormat
}
~~~

The key deliberately includes the normalized WPE blend string and color pixel format. Depth pixel format is constant (`.depth32Float`) for these fullscreen built-ins and does not need a separate key dimension.

### Ping-Pong Semantics For `previous`

For a pass targeting `.fbo("_rt_A")`:

- `.previous` resolves to the latest texture registered for logical target `_rt_A`.
- If the pass writes `_rt_A` while reading `.previous`, the destination texture must not be the same object as the previous read texture.
- After the pass encodes successfully, the destination becomes the latest texture for `_rt_A`.
- If `.previous` is requested before the current target has any prior write in the frame, throw `WPEMetalRenderExecutorError.missingTexture(.previous)`.

For `.layerComposite(name)`, the logical target name is the layer-private FBO name. Reads through `.fbo(name)` resolve to the latest layer-composite write because graph builder already emits `.fbo(compositeA)` between layer passes.

### Rejected Alternatives

- **Do not add a second executor.** The existing executor already owns command queue, library, output texture creation, and presentation.
- **Do not persist `previous` across frames.** Phase 2C needs intra-frame pass chaining. Previous-frame feedback is a follow-up and would require explicit lifecycle and clear semantics.
- **Do not key FBOs by pass ID.** WPE effects intentionally share named FBOs; keying by pass would break cross-pass reads.
- **Do not touch `WPESceneDetailView`.** Phase 2C has no UI surface.
- **Do not implement custom GLSL dispatch.** Non-built-in shader programs still throw `unsupportedShader` until Phase 2D.

### Assumptions

- The default FBO format for undeclared layer composites is `rgba8888`, mapped to `WPEMetalRenderExecutor.outputPixelFormat`.
- `rgba_backbuffer`, `rgba8888`, and unknown RGBA aliases map to the existing sRGB output format for SpriteKit parity.
- `rgba16f`/`rgba_half` map to `.rgba16Float`; `r8` maps to `.r8Unorm`; unsupported FBO format strings fall back to output format with a diagnostic log, not a hard failure.
- `normalmapped` uses the same blend factors as `normal`; Phase 2D can refine this if translated WPE shaders prove it needs a specialized state.
- `unique` is preserved on `WPERenderFBO` but not included in the Phase 2C allocation key because the authoritative requirement specifies `(name, sceneRenderSize, scale, format)`. If real scenes show cross-layer leakage for `unique == true`, add a Phase 2C follow-up to include layer identity for those FBOs only.

### Potential Side Effects

- `WPEMetalRenderExecutor` will retain pooled transient textures after `render(...)`; memory use increases until `.suspended`, `reload()`, or `cleanup()`.
- Blend behavior changes for all built-in scene passes because existing code ignored `WPERenderPass.blending`.
- Passes with `cullMode == "front"` can intentionally render nothing with the fullscreen quad because the built-in vertex winding is counter-clockwise.
- Depth-enabled fullscreen passes share one target-sized depth texture per pooled target; this is enough for current built-ins but not a replacement for Phase 2H object/model depth handling.

---

## Scope

### In Scope

- Route pass targets:
  - `.scene` → existing scene output texture.
  - `.fbo(name)` → pooled named FBO texture.
  - `.layerComposite(name)` → pooled layer-private scratch texture addressable by `.fbo(name)`.
- Allocate and recycle FBO/layer-composite textures across frames.
- Prefer `MTLHeap`; fall back to discrete `MTLTexture` allocation.
- Release pooled transient textures on `WPEMetalSceneRenderer.applyPerformanceProfile(.suspended)`.
- Resolve `.previous` and `.fbo(name)` from executor frame state.
- Ping-pong same-target writes that read `.previous`.
- Map WPE blend strings:
  - `normal`
  - `additive`
  - `multiply`
  - `translucent`
  - `normalmapped`
  - `disabled`
- Map cull strings:
  - `nocull`
  - `back`
  - `front`
- Map depth test/write strings and attach a `.depth32Float` depth target when needed.
- Add built-in util shader support:
  - `solidlayer`
  - `copy`
  - `compose`
  - aliases under `materials/util/*.json` and `materials/util/*`.

### Out Of Scope

- Custom GLSL shader translation or runtime compilation.
- Particles.
- Audio uniforms.
- Web objects.
- Animated/video TEX.
- Previous-frame feedback/readback timers.
- UI changes, including `WPESceneDetailView`.
- Any new third-party dependency.

---

## File Structure

### New Files

- `LiveWallpaper/Runtime/WPEMetalRenderTargetPool.swift`
  - Persistent FBO/layer-composite allocation pool, heap fallback, target keying, allocation counters for tests.

### Existing Files To Modify

- `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Frame target state, target routing, source resolution, ping-pong, blend/cull/depth state, pipeline cache key, util shader dispatch.
- `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
  - Release executor transient resources on `.suspended`, `reload()`, and `cleanup()`; update texture reference discovery for util built-ins.
- `LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift`
  - Recognize `solidlayer`, `copy`, and `compose` util built-ins and their material-path aliases.
- `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
  - Add `wpe_solidlayer_fragment`, `wpe_util_copy_fragment`, and `wpe_compose_fragment`.

### Test Files

- `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
  - Target routing, FBO source resolution, previous ping-pong, blend/cull/depth golden pixels, util shader pixels.
- `LiveWallpaperTests/WPERenderPipelineBuilderTests.swift`
  - Util shader alias preparation.
- `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`
  - Multi-pass scene load and suspended resource release.

---

## Task 1: Route `.fbo` And `.layerComposite` Targets

**Files:**

- Create: none
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these tests and helpers to `WPEMetalRenderExecutorTests.swift`. They fail now because `encode(...)` throws `unsupportedTarget` for `.fbo` and `.layerComposite`, and `resolve(.fbo)` still treats FBO names as missing external textures.

~~~swift
private extension WPEMetalRenderExecutorTests {
    @Test("Routes layerComposite target into a later FBO source")
    func routesLayerCompositeTargetIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compositeName = "_rt_imageLayerComposite_layer_a"
        let writeComposite = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .layerComposite(name: compositeName),
            blending: "disabled"
        )
        let copyToScene = copyPass(
            id: "layer.1",
            source: .fbo(compositeName),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(writeComposite, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(copyToScene, bindings: [0: .fbo(compositeName)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Routes declared FBO target into a later FBO source")
    func routesDeclaredFBOTargetIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_CustomBuffer", scale: 1, format: "rgba8888")
        let writeFBO = solidPass(
            id: "layer.0",
            color: [0, 1, 0, 1],
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyToScene = copyPass(
            id: "layer.1",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(writeFBO, uniforms: ["g_Color": .vector([0, 1, 0, 1])]),
                preparedBuiltinPass(copyToScene, bindings: [0: .fbo(fbo.name)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r <= 5)
        #expect(pixel.g >= 250)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }
}

private func solidPass(
    id: String,
    color: [Double],
    target: WPERenderTarget,
    blending: String = "normal",
    cullMode: String = "nocull",
    depthTest: String = "disabled",
    depthWrite: String = "disabled"
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .material,
        shader: "solidcolor",
        source: .previous,
        target: target,
        textures: [:],
        binds: [:],
        constants: ["g_Color": .vector(color)],
        combos: [:],
        blending: blending,
        cullMode: cullMode,
        depthTest: depthTest,
        depthWrite: depthWrite
    )
}

private func copyPass(
    id: String,
    source: WPETextureReference,
    target: WPERenderTarget,
    blending: String = "normal",
    cullMode: String = "nocull",
    depthTest: String = "disabled",
    depthWrite: String = "disabled"
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .command(file: "effects/copy/effect.json"),
        shader: "commands/copy",
        source: source,
        target: target,
        textures: [0: source],
        binds: [:],
        constants: [:],
        combos: [:],
        blending: blending,
        cullMode: cullMode,
        depthTest: depthTest,
        depthWrite: depthWrite
    )
}

private func preparedPipeline(
    localFBOs: [WPERenderFBO],
    passes: [WPEPreparedRenderPass]
) -> WPEPreparedRenderPipeline {
    let layer = WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        compositeA: "_rt_imageLayerComposite_layer_a",
        compositeB: "_rt_imageLayerComposite_layer_b",
        localFBOs: localFBOs,
        passes: passes.map(\.pass)
    )
    return WPEPreparedRenderPipeline(layers: [
        WPEPreparedRenderLayer(graphLayer: layer, passes: passes)
    ])
}

private func preparedBuiltinPass(
    _ pass: WPERenderPass,
    bindings: [Int: WPETextureReference] = [:],
    uniforms: [String: WPESceneShaderConstantValue] = [:]
) -> WPEPreparedRenderPass {
    WPEPreparedRenderPass(
        pass: pass,
        shader: WPEShaderProgram(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
        textureBindings: bindings,
        comboValues: [:],
        uniformValues: uniforms
    )
}
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: FAIL with `unsupportedTarget(.layerComposite(...))` or `missingTexture(.fbo(...))`.

- [ ] **Step 3: Add frame-local target state**

In `WPEMetalRenderExecutor.swift`, add these private types below `WPESolidUniforms`.

~~~swift
private enum WPEMetalTargetID: Hashable {
    case scene
    case named(String)

    init(target: WPERenderTarget) {
        switch target {
        case .scene:
            self = .scene
        case .fbo(let name), .layerComposite(let name):
            self = .named(name)
        }
    }
}

private struct WPEMetalFrameState {
    let output: MTLTexture
    let sceneSize: CGSize
    var latestSceneTexture: MTLTexture?
    var latestNamedTextures: [String: MTLTexture] = [:]
    var writtenTargets: Set<WPEMetalTargetID> = []

    func latestTexture(for targetID: WPEMetalTargetID) -> MTLTexture? {
        switch targetID {
        case .scene:
            return latestSceneTexture
        case .named(let name):
            return latestNamedTextures[name]
        }
    }

    mutating func registerWrite(texture: MTLTexture, targetID: WPEMetalTargetID) {
        writtenTargets.insert(targetID)
        switch targetID {
        case .scene:
            latestSceneTexture = texture
        case .named(let name):
            latestNamedTextures[name] = texture
        }
    }

    func hasWritten(_ targetID: WPEMetalTargetID) -> Bool {
        writtenTargets.contains(targetID)
    }
}
~~~

- [ ] **Step 4: Route targets to textures**

Add a temporary discrete texture allocator. Task 2 replaces this with the reusable heap-backed pool.

~~~swift
private func makeTransientTargetTexture(
    name: String,
    size: CGSize,
    scale: Double,
    format: String
) throws -> MTLTexture {
    let width = max(Int((size.width * scale).rounded()), 1)
    let height = max(Int((size.height * scale).rounded()), 1)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat(forFBOFormat: format),
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw WPEMetalTextureLoaderError.textureAllocationFailed
    }
    texture.label = "WPE transient target \(name)"
    return texture
}

private func pixelFormat(forFBOFormat format: String) -> MTLPixelFormat {
    switch format.lowercased() {
    case "rgba16f", "rgba_half", "rgba16161616f":
        return .rgba16Float
    case "r8", "r8unorm":
        return .r8Unorm
    default:
        return Self.outputPixelFormat
    }
}

private func fboDeclaration(
    named name: String,
    in layer: WPERenderLayer
) -> WPERenderFBO {
    layer.localFBOs.first(where: { $0.name == name })
        ?? WPERenderFBO(name: name, scale: 1, format: "rgba8888")
}

private func targetTexture(
    for target: WPERenderTarget,
    layer: WPERenderLayer,
    frameState: inout WPEMetalFrameState
) throws -> (id: WPEMetalTargetID, texture: MTLTexture) {
    let targetID = WPEMetalTargetID(target: target)
    switch target {
    case .scene:
        return (targetID, frameState.output)

    case .layerComposite(let name):
        if let existing = frameState.latestNamedTextures[name] {
            return (targetID, existing)
        }
        let texture = try makeTransientTargetTexture(
            name: name,
            size: frameState.sceneSize,
            scale: 1,
            format: "rgba8888"
        )
        return (targetID, texture)

    case .fbo(let name):
        if let existing = frameState.latestNamedTextures[name] {
            return (targetID, existing)
        }
        let fbo = fboDeclaration(named: name, in: layer)
        let texture = try makeTransientTargetTexture(
            name: name,
            size: frameState.sceneSize,
            scale: fbo.scale,
            format: fbo.format
        )
        return (targetID, texture)
    }
}
~~~

- [ ] **Step 5: Thread frame state through render and encode**

Update `render(...)` to create `WPEMetalFrameState`, pass it into `encode(...)`, and register writes.

~~~swift
func render(
    pipeline: WPEPreparedRenderPipeline,
    size: CGSize,
    textures: [String: MTLTexture]
) throws -> MTLTexture {
    let output = try makeOutputTexture(size: size)
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }

    var frameState = WPEMetalFrameState(output: output, sceneSize: size)
    var didEncode = false

    for layer in pipeline.layers {
        if layer.passes.isEmpty {
            try encodeCopy(
                reference: .image(layer.graphLayer.imagePath),
                target: .scene,
                layer: layer.graphLayer,
                textures: textures,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
            didEncode = true
            continue
        }

        for pass in layer.passes {
            try encode(
                pass: pass,
                layer: layer.graphLayer,
                textures: textures,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
            didEncode = true
        }
    }

    guard didEncode else {
        throw WPEMetalRenderExecutorError.noRenderablePasses
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if commandBuffer.status == .error {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }
    return output
}
~~~

Replace the start of `encode(...)` with target dispatch.

~~~swift
private func encode(
    pass: WPEPreparedRenderPass,
    layer: WPERenderLayer,
    textures: [String: MTLTexture],
    commandBuffer: MTLCommandBuffer,
    frameState: inout WPEMetalFrameState
) throws {
    let destination = try targetTexture(
        for: pass.pass.target,
        layer: layer,
        frameState: &frameState
    )

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = destination.texture
    descriptor.colorAttachments[0].loadAction = frameState.hasWritten(destination.id) ? .load : .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }
    defer { encoder.endEncoding() }

    if pass.pass.shader == "solidcolor" {
        encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_solidcolor_fragment"))
        var uniforms = WPESolidUniforms(color: colorVector(for: pass))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
    } else if pass.pass.shader == "commands/copy" || pass.pass.shader.hasPrefix("genericimage") {
        encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
        let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let texture = try resolve(
            reference: reference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        encoder.setFragmentTexture(texture, index: 0)
    } else {
        throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
    }

    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    frameState.registerWrite(texture: destination.texture, targetID: destination.id)
}
~~~

Update `encodeCopy(...)` similarly.

~~~swift
private func encodeCopy(
    reference: WPETextureReference,
    target: WPERenderTarget,
    layer: WPERenderLayer,
    textures: [String: MTLTexture],
    commandBuffer: MTLCommandBuffer,
    frameState: inout WPEMetalFrameState
) throws {
    let destination = try targetTexture(for: target, layer: layer, frameState: &frameState)

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = destination.texture
    descriptor.colorAttachments[0].loadAction = frameState.hasWritten(destination.id) ? .load : .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }
    defer { encoder.endEncoding() }

    encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
    encoder.setFragmentTexture(
        try resolve(
            reference: reference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        ),
        index: 0
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    frameState.registerWrite(texture: destination.texture, targetID: destination.id)
}
~~~

- [ ] **Step 6: Resolve FBO sources from frame state**

Replace the existing `resolve(reference:textures:)`.

~~~swift
private func resolve(
    reference: WPETextureReference,
    textures: [String: MTLTexture],
    frameState: WPEMetalFrameState,
    currentTargetID: WPEMetalTargetID
) throws -> MTLTexture {
    switch reference {
    case .image(let path), .asset(let path):
        guard let texture = textures[path] else {
            throw WPEMetalRenderExecutorError.missingTexture(reference)
        }
        return texture

    case .fbo(let name):
        guard let texture = frameState.latestNamedTextures[name] else {
            throw WPEMetalRenderExecutorError.missingTexture(reference)
        }
        return texture

    case .previous:
        guard let texture = frameState.latestTexture(for: currentTargetID) else {
            throw WPEMetalRenderExecutorError.missingTexture(reference)
        }
        return texture
    }
}
~~~

- [ ] **Step 7: Run targeted tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: PASS for the new target routing tests and existing executor tests.

---

## Task 2: Add Heap-Backed FBO Pool And Suspended Release

**Files:**

- Create: `LiveWallpaper/Runtime/WPEMetalRenderTargetPool.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Write failing allocation/release tests**

Append to `WPEMetalRenderExecutorTests.swift`.

~~~swift
private extension WPEMetalRenderExecutorTests {
    @Test("Reuses pooled FBO allocations across render calls")
    func reusesPooledFBOAllocationsAcrossFrames() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_Reused", scale: 1, format: "rgba8888")
        let write = solidPass(
            id: "layer.0",
            color: [0, 0, 1, 1],
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copy = copyPass(
            id: "layer.1",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(write, uniforms: ["g_Color": .vector([0, 0, 1, 1])]),
                preparedBuiltinPass(copy, bindings: [0: .fbo(fbo.name)])
            ]
        )

        _ = try executor.render(pipeline: pipeline, size: CGSize(width: 8, height: 8), textures: [:])
        let firstAllocationCount = executor.transientTargetTextureCountForTesting
        _ = try executor.render(pipeline: pipeline, size: CGSize(width: 8, height: 8), textures: [:])
        let secondAllocationCount = executor.transientTargetTextureCountForTesting

        #expect(firstAllocationCount > 0)
        #expect(secondAllocationCount == firstAllocationCount)
    }

    @Test("Releases pooled FBO allocations on explicit transient release")
    func releasesPooledFBOAllocations() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_Releasable", scale: 1, format: "rgba8888")
        let write = solidPass(
            id: "layer.0",
            color: [1, 1, 0, 1],
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copy = copyPass(
            id: "layer.1",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(write, uniforms: ["g_Color": .vector([1, 1, 0, 1])]),
                preparedBuiltinPass(copy, bindings: [0: .fbo(fbo.name)])
            ]
        )

        _ = try executor.render(pipeline: pipeline, size: CGSize(width: 8, height: 8), textures: [:])
        #expect(executor.transientTargetTextureCountForTesting > 0)

        executor.releaseTransientResources()

        #expect(executor.transientTargetTextureCountForTesting == 0)
    }
}
~~~

Append to `WPEMetalSceneRendererTests.swift`.

~~~swift
extension WPEMetalSceneRendererTests {
    @Test("Suspended profile releases Metal executor transient FBOs")
    func suspendedProfileReleasesExecutorTransientFBOs() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.fboCopyScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()
        #expect(renderer.transientTargetTextureCountForTesting > 0)

        renderer.applyPerformanceProfile(.suspended)

        #expect(renderer.transientTargetTextureCountForTesting == 0)
    }
}

private extension MetalSceneFixture {
    static func fboCopyScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        let effects = root.appendingPathComponent("effects/fbo", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: effects, withIntermediateDirectories: true)

        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: root.appendingPathComponent("model.json"))
        try Data("""
        {
          "passes": [{
            "shader": "solidcolor",
            "constantshadervalues": { "g_Color": "0 0 1 1" }
          }]
        }
        """.utf8).write(to: materials.appendingPathComponent("base.json"))
        try Data("""
        {
          "fbos": [{ "name": "_rt_Releasable", "scale": 1, "format": "rgba8888" }],
          "passes": [{
            "command": "copy",
            "source": "_rt_imageLayerComposite_image_a",
            "target": "_rt_Releasable"
          }, {
            "command": "copy",
            "source": "_rt_Releasable"
          }]
        }
        """.utf8).write(to: effects.appendingPathComponent("effect.json"))

        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "image",
            "name": "Image",
            "type": "image",
            "image": "model.json",
            "effects": [{ "id": 1, "file": "effects/fbo/effect.json" }]
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))

        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }
}
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected: FAIL because `transientTargetTextureCountForTesting`, `releaseTransientResources()`, and scene renderer forwarding do not exist.

- [ ] **Step 3: Create the render target pool**

Create `LiveWallpaper/Runtime/WPEMetalRenderTargetPool.swift`.

~~~swift
import CoreGraphics
import Foundation
import Metal

struct WPEMetalRenderTargetKey: Hashable {
    let name: String
    let sceneWidth: Int
    let sceneHeight: Int
    let scale: Double
    let format: String
    let pixelFormat: MTLPixelFormat

    init(name: String, sceneSize: CGSize, scale: Double, format: String, pixelFormat: MTLPixelFormat) {
        self.name = name
        self.sceneWidth = max(Int(sceneSize.width.rounded()), 1)
        self.sceneHeight = max(Int(sceneSize.height.rounded()), 1)
        self.scale = scale
        self.format = format.lowercased()
        self.pixelFormat = pixelFormat
    }
}

final class WPEMetalRenderTargetPool {
    private struct Allocation {
        let texture: MTLTexture
        let heap: MTLHeap?
    }

    private final class Slot {
        var primary: Allocation?
        var secondary: Allocation?
    }

    private let device: MTLDevice
    private var slots: [WPEMetalRenderTargetKey: Slot] = [:]
    private var declaredFBOs: [String: WPERenderFBO] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    var allocatedTextureCount: Int {
        slots.values.reduce(0) { count, slot in
            count + (slot.primary == nil ? 0 : 1) + (slot.secondary == nil ? 0 : 1)
        }
    }

    func prepare(pipeline: WPEPreparedRenderPipeline) {
        declaredFBOs.removeAll(keepingCapacity: true)
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declaredFBOs[fbo.name] = fbo
            }
        }
    }

    func releaseAll() {
        slots.removeAll(keepingCapacity: true)
        declaredFBOs.removeAll(keepingCapacity: true)
    }

    func texture(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        avoiding textureToAvoid: MTLTexture?
    ) throws -> MTLTexture {
        let spec = targetSpec(for: target, layer: layer)
        let pixelFormat = Self.pixelFormat(forFBOFormat: spec.format)
        let key = WPEMetalRenderTargetKey(
            name: spec.name,
            sceneSize: sceneSize,
            scale: spec.scale,
            format: spec.format,
            pixelFormat: pixelFormat
        )
        let slot = slots[key] ?? Slot()
        slots[key] = slot

        if slot.primary == nil {
            slot.primary = try makeAllocation(key: key, label: "primary")
        }

        if let textureToAvoid,
           let primary = slot.primary,
           primary.texture === textureToAvoid {
            if slot.secondary == nil {
                slot.secondary = try makeAllocation(key: key, label: "secondary")
            }
            return slot.secondary!.texture
        }

        return slot.primary!.texture
    }

    private func targetSpec(for target: WPERenderTarget, layer: WPERenderLayer) -> WPERenderFBO {
        switch target {
        case .scene:
            return WPERenderFBO(name: "scene", scale: 1, format: "rgba8888")

        case .layerComposite(let name):
            return WPERenderFBO(name: name, scale: 1, format: "rgba8888")

        case .fbo(let name):
            return declaredFBOs[name]
                ?? layer.localFBOs.first(where: { $0.name == name })
                ?? WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        }
    }

    private func makeAllocation(key: WPEMetalRenderTargetKey, label: String) throws -> Allocation {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: max(Int((Double(key.sceneWidth) * key.scale).rounded()), 1),
            height: max(Int((Double(key.sceneHeight) * key.scale).rounded()), 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
        if sizeAndAlign.size > 0 {
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.storageMode = descriptor.storageMode
            heapDescriptor.size = Self.align(sizeAndAlign.size, to: sizeAndAlign.align)
            if let heap = device.makeHeap(descriptor: heapDescriptor),
               let texture = heap.makeTexture(descriptor: descriptor) {
                texture.label = "WPE \(key.name) \(label) heap texture"
                return Allocation(texture: texture, heap: heap)
            }
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE \(key.name) \(label) texture"
        return Allocation(texture: texture, heap: nil)
    }

    private static func align(_ size: Int, to alignment: Int) -> Int {
        guard alignment > 0 else { return size }
        let remainder = size % alignment
        return remainder == 0 ? size : size + alignment - remainder
    }

    static func pixelFormat(forFBOFormat format: String) -> MTLPixelFormat {
        switch format.lowercased() {
        case "rgba16f", "rgba_half", "rgba16161616f":
            return .rgba16Float
        case "r8", "r8unorm":
            return .r8Unorm
        default:
            return WPEMetalRenderExecutor.outputPixelFormat
        }
    }
}
~~~

- [ ] **Step 4: Replace transient allocation in executor with the pool**

In `WPEMetalRenderExecutor.swift`, add the pool property.

~~~swift
private let targetPool: WPEMetalRenderTargetPool
~~~

Initialize it in `init(device:)`.

~~~swift
self.targetPool = WPEMetalRenderTargetPool(device: device)
~~~

Add testing and release accessors.

~~~swift
var transientTargetTextureCountForTesting: Int {
    targetPool.allocatedTextureCount
}

func releaseTransientResources() {
    targetPool.releaseAll()
}
~~~

At the start of `render(...)`, after the command buffer is created, prepare the pool.

~~~swift
targetPool.prepare(pipeline: pipeline)
var frameState = WPEMetalFrameState(output: output, sceneSize: size)
~~~

Replace `targetTexture(...)` implementation so `.scene` uses output and all named targets use the pool.

~~~swift
private func targetTexture(
    for target: WPERenderTarget,
    layer: WPERenderLayer,
    frameState: inout WPEMetalFrameState,
    avoiding textureToAvoid: MTLTexture? = nil
) throws -> (id: WPEMetalTargetID, texture: MTLTexture) {
    let targetID = WPEMetalTargetID(target: target)
    switch target {
    case .scene:
        return (targetID, frameState.output)
    case .fbo, .layerComposite:
        let texture = try targetPool.texture(
            for: target,
            layer: layer,
            sceneSize: frameState.sceneSize,
            avoiding: textureToAvoid
        )
        return (targetID, texture)
    }
}
~~~

Remove the temporary `makeTransientTargetTexture`, `pixelFormat(forFBOFormat:)`, and `fboDeclaration(...)` helpers added in Task 1.

- [ ] **Step 5: Release resources from scene renderer**

In `WPEMetalSceneRenderer.swift`, add a test-only forwarding property.

~~~swift
var transientTargetTextureCountForTesting: Int {
    executor.transientTargetTextureCountForTesting
}
~~~

Update `reload()` and `cleanup()`.

~~~swift
func reload() async throws {
    didLoad = false
    hasPresentedFrame = false
    outputTexture = nil
    renderGraph = nil
    renderPipeline = nil
    loadDiagnostics = nil
    executor.releaseTransientResources()
    try await load()
}

func cleanup() {
    mtkView.delegate = nil
    outputTexture = nil
    executor.releaseTransientResources()
}
~~~

Update the suspended branch.

~~~swift
case .suspended:
    mtkView.isPaused = true
    mtkView.enableSetNeedsDisplay = false
    mtkView.releaseDrawables()
    executor.releaseTransientResources()
~~~

- [ ] **Step 6: Run targeted tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected: PASS. The renderer test proves `.suspended` releases pooled FBOs.

---

## Task 3: Implement `previous` Source Resolution And Same-Target Ping-Pong

**Files:**

- Create: none
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write failing previous/ping-pong tests**

Append to `WPEMetalRenderExecutorTests.swift`.

~~~swift
private extension WPEMetalRenderExecutorTests {
    @Test("Resolves previous to the most recent write to the same FBO target")
    func resolvesPreviousWithinSameFBOTarget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let checker = try makeCheckerTexture(device: device)
        let fbo = WPERenderFBO(name: "_rt_Checker", scale: 1, format: "rgba8888")

        let seedFBO = copyPass(
            id: "layer.0",
            source: .image("materials/checker.png"),
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyPreviousBackIntoSameFBO = copyPass(
            id: "layer.1",
            source: .previous,
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyFBOToScene = copyPass(
            id: "layer.2",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(seedFBO, bindings: [0: .image("materials/checker.png")]),
                preparedBuiltinPass(copyPreviousBackIntoSameFBO, bindings: [0: .previous]),
                preparedBuiltinPass(copyFBOToScene, bindings: [0: .fbo(fbo.name)])
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/checker.png": checker]
        )

        #expect(try readPixel(output, x: 0, y: 0).r >= 250)
        #expect(try readPixel(output, x: 1, y: 0).g >= 250)
        #expect(try readPixel(output, x: 0, y: 1).b >= 250)
        #expect(try readPixel(output, x: 1, y: 1).r >= 250)
        #expect(try readPixel(output, x: 1, y: 1).g >= 250)
    }

    @Test("Missing previous fails closed before any write to the current target")
    func missingPreviousFailsClosed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_Empty", scale: 1, format: "rgba8888")
        let pass = copyPass(
            id: "layer.0",
            source: .previous,
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [preparedBuiltinPass(pass, bindings: [0: .previous])]
        )

        #expect(throws: WPEMetalRenderExecutorError.missingTexture(.previous)) {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: [:])
        }
    }
}

private func makeCheckerTexture(device: MTLDevice) throws -> MTLTexture {
    try makeRGBAInputTexture(device: device, bytes: Data([
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 0,   255
    ]))
}
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: FAIL because same-target `.previous` either throws or samples from the destination texture without ping-ponging.

- [ ] **Step 3: Detect when a pass reads its own target**

Add these helpers to `WPEMetalRenderExecutor.swift`.

~~~swift
private func passReadsCurrentTarget(_ pass: WPEPreparedRenderPass, targetID: WPEMetalTargetID) -> Bool {
    textureReferences(for: pass).contains { reference in
        switch (reference, targetID) {
        case (.previous, _):
            return true
        case (.fbo(let name), .named(let targetName)):
            return name == targetName
        default:
            return false
        }
    }
}

private func textureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
    var references: [WPETextureReference] = [pass.pass.source]
    references.append(contentsOf: pass.pass.textures.values)
    references.append(contentsOf: pass.pass.binds.values)
    references.append(contentsOf: pass.textureBindings.values)
    return references
}
~~~

- [ ] **Step 4: Ask the pool for an alternate destination when needed**

Update the top of `encode(...)`.

~~~swift
let targetID = WPEMetalTargetID(target: pass.pass.target)
let previousTextureForTarget = frameState.latestTexture(for: targetID)
let destination = try targetTexture(
    for: pass.pass.target,
    layer: layer,
    frameState: &frameState,
    avoiding: passReadsCurrentTarget(pass, targetID: targetID) ? previousTextureForTarget : nil
)
~~~

Update `encodeCopy(...)` the same way.

~~~swift
let targetID = WPEMetalTargetID(target: target)
let previousTextureForTarget = frameState.latestTexture(for: targetID)
let destination = try targetTexture(
    for: target,
    layer: layer,
    frameState: &frameState,
    avoiding: reference == .previous ? previousTextureForTarget : nil
)
~~~

- [ ] **Step 5: Keep resolve semantics target-local**

Keep `.previous` resolution exactly target-local. This is the contract:

~~~swift
case .previous:
    guard let texture = frameState.latestTexture(for: currentTargetID) else {
        throw WPEMetalRenderExecutorError.missingTexture(reference)
    }
    return texture
~~~

- [ ] **Step 6: Run targeted tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: PASS. The checkerboard proves same-target ping-pong keeps the prior FBO contents readable while writing a new physical FBO texture.

---

## Task 4: Map Blend, Cull, And Depth State

**Files:**

- Create: none
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write failing render-state tests**

Append to `WPEMetalRenderExecutorTests.swift`.

~~~swift
private struct BlendFixture: Sendable {
    let mode: String
    let expected: Pixel
}

private let blendFixtures: [BlendFixture] = [
    BlendFixture(mode: "normal", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "additive", expected: Pixel(r: 188, g: 0, b: 255, a: 255)),
    BlendFixture(mode: "multiply", expected: Pixel(r: 0, g: 0, b: 0, a: 255)),
    BlendFixture(mode: "translucent", expected: Pixel(r: 255, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "normalmapped", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "disabled", expected: Pixel(r: 255, g: 0, b: 0, a: 128))
]

private extension WPEMetalRenderExecutorTests {
    @Test("Applies WPE blend factors", arguments: blendFixtures)
    func appliesWPEBlendFactors(fixture: BlendFixture) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let destination = solidPass(
            id: "layer.0",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled"
        )
        let source = solidPass(
            id: "layer.1",
            color: [1, 0, 0, 0.5],
            target: .scene,
            blending: fixture.mode
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(destination, uniforms: ["g_Color": .vector([0, 0, 1, 1])]),
                preparedBuiltinPass(source, uniforms: ["g_Color": .vector([1, 0, 0, 0.5])])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(abs(Int(pixel.r) - Int(fixture.expected.r)) <= 2)
        #expect(abs(Int(pixel.g) - Int(fixture.expected.g)) <= 2)
        #expect(abs(Int(pixel.b) - Int(fixture.expected.b)) <= 2)
        #expect(abs(Int(pixel.a) - Int(fixture.expected.a)) <= 2)
    }

    @Test("Front culling discards the fullscreen built-in quad")
    func frontCullingDiscardsFullscreenQuad() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let red = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .scene,
            blending: "disabled"
        )
        let culledBlue = solidPass(
            id: "layer.1",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled",
            cullMode: "front"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(red, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(culledBlue, uniforms: ["g_Color": .vector([0, 0, 1, 1])])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
    }

    @Test("Depth less test rejects equal-depth fullscreen pass")
    func depthLessRejectsEqualDepthPass() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let red = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .scene,
            blending: "disabled",
            depthTest: "always",
            depthWrite: "enabled"
        )
        let rejectedBlue = solidPass(
            id: "layer.1",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled",
            depthTest: "less",
            depthWrite: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(red, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(rejectedBlue, uniforms: ["g_Color": .vector([0, 0, 1, 1])])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
    }
}
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: FAIL because blending, culling, and depth state are ignored.

- [ ] **Step 3: Add pipeline and depth cache keys**

In `WPEMetalRenderExecutor.swift`, replace the pipeline dictionary.

~~~swift
private var pipelines: [WPEMetalPipelineKey: MTLRenderPipelineState] = [:]
private var depthStates: [WPEMetalDepthKey: MTLDepthStencilState] = [:]

private struct WPEMetalPipelineKey: Hashable {
    let fragmentName: String
    let blendMode: String
    let colorPixelFormat: MTLPixelFormat
}

private struct WPEMetalDepthKey: Hashable {
    let depthTest: String
    let depthWrite: String
}
~~~

Add a test accessor.

~~~swift
var pipelineStateCountForTesting: Int {
    pipelines.count
}
~~~

- [ ] **Step 4: Apply blend descriptors in PSO creation**

Replace `renderPipeline(fragmentName:)`.

~~~swift
private func renderPipeline(
    fragmentName: String,
    blendMode: String = "disabled",
    colorPixelFormat: MTLPixelFormat = Self.outputPixelFormat
) throws -> MTLRenderPipelineState {
    let normalizedBlend = blendMode.lowercased()
    let key = WPEMetalPipelineKey(
        fragmentName: fragmentName,
        blendMode: normalizedBlend,
        colorPixelFormat: colorPixelFormat
    )
    if let cached = pipelines[key] {
        return cached
    }

    guard let vertex = library.makeFunction(name: "wpe_fullscreen_vertex"),
          let fragment = library.makeFunction(name: fragmentName) else {
        throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
    descriptor.depthAttachmentPixelFormat = .depth32Float
    applyBlendMode(normalizedBlend, to: descriptor.colorAttachments[0])

    let state = try device.makeRenderPipelineState(descriptor: descriptor)
    pipelines[key] = state
    return state
}

private func applyBlendMode(
    _ mode: String,
    to attachment: MTLRenderPipelineColorAttachmentDescriptor
) {
    switch mode {
    case "disabled":
        attachment.isBlendingEnabled = false

    case "additive":
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one

    case "multiply":
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .destinationColor
        attachment.destinationRGBBlendFactor = .zero
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .zero

    case "translucent":
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    case "normalmapped", "normal":
        fallthrough

    default:
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
}
~~~

Update all executor calls:

~~~swift
encoder.setRenderPipelineState(try renderPipeline(
    fragmentName: "wpe_solidcolor_fragment",
    blendMode: pass.pass.blending,
    colorPixelFormat: destination.texture.pixelFormat
))
~~~

For present, keep blending disabled.

~~~swift
encoder.setRenderPipelineState(try renderPipeline(
    fragmentName: "wpe_copy_fragment",
    blendMode: "disabled",
    colorPixelFormat: drawable.texture.pixelFormat
))
~~~

- [ ] **Step 5: Apply cull mode**

Add the mapper.

~~~swift
private func cullMode(for raw: String) -> MTLCullMode {
    switch raw.lowercased() {
    case "back":
        return .back
    case "front":
        return .front
    default:
        return .none
    }
}
~~~

Set it in `encode(...)` and `encodeCopy(...)` after creating the encoder.

~~~swift
encoder.setFrontFacing(.counterClockwise)
encoder.setCullMode(cullMode(for: pass.pass.cullMode))
~~~

For `encodeCopy(...)`, use `.none` because image-layer fallback copies have no authored pass state.

~~~swift
encoder.setFrontFacing(.counterClockwise)
encoder.setCullMode(.none)
~~~

- [ ] **Step 6: Add depth texture and depth state**

Add depth storage to `WPEMetalFrameState`.

~~~swift
var depthTextures: [WPEMetalTargetID: MTLTexture] = [:]
~~~

Add helpers.

~~~swift
private func needsDepthAttachment(pass: WPEPreparedRenderPass) -> Bool {
    pass.pass.depthWrite.lowercased() == "enabled"
        || pass.pass.depthWrite.lowercased() == "true"
        || pass.pass.depthTest.lowercased() != "disabled"
}

private func makeDepthTexture(size: CGSize) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .depth32Float,
        width: max(Int(size.width.rounded()), 1),
        height: max(Int(size.height.rounded()), 1),
        mipmapped: false
    )
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .private

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw WPEMetalTextureLoaderError.textureAllocationFailed
    }
    texture.label = "WPE Metal executor depth"
    return texture
}

private func depthTexture(
    for targetID: WPEMetalTargetID,
    frameState: inout WPEMetalFrameState
) throws -> MTLTexture {
    if let existing = frameState.depthTextures[targetID] {
        return existing
    }
    let texture = try makeDepthTexture(size: frameState.sceneSize)
    frameState.depthTextures[targetID] = texture
    return texture
}

private func depthStencilState(depthTest: String, depthWrite: String) -> MTLDepthStencilState {
    let key = WPEMetalDepthKey(
        depthTest: depthTest.lowercased(),
        depthWrite: depthWrite.lowercased()
    )
    if let cached = depthStates[key] {
        return cached
    }

    let descriptor = MTLDepthStencilDescriptor()
    descriptor.depthCompareFunction = depthCompareFunction(for: key.depthTest)
    descriptor.isDepthWriteEnabled = key.depthWrite == "enabled" || key.depthWrite == "true"

    let state = device.makeDepthStencilState(descriptor: descriptor)!
    depthStates[key] = state
    return state
}

private func depthCompareFunction(for raw: String) -> MTLCompareFunction {
    switch raw.lowercased() {
    case "always":
        return .always
    case "never":
        return .never
    case "less":
        return .less
    case "lequal", "lessequal", "less_equal":
        return .lessEqual
    case "greater":
        return .greater
    case "gequal", "greaterequal", "greater_equal":
        return .greaterEqual
    case "equal":
        return .equal
    case "notequal", "not_equal":
        return .notEqual
    default:
        return .always
    }
}
~~~

In `encode(...)`, before creating the encoder, attach depth when needed.

~~~swift
if needsDepthAttachment(pass: pass) {
    let depth = try depthTexture(for: destination.id, frameState: &frameState)
    descriptor.depthAttachment.texture = depth
    descriptor.depthAttachment.loadAction = frameState.hasWritten(destination.id) ? .load : .clear
    descriptor.depthAttachment.storeAction = .store
    descriptor.depthAttachment.clearDepth = 1
}
~~~

After creating the encoder, set depth state.

~~~swift
encoder.setDepthStencilState(depthStencilState(
    depthTest: pass.pass.depthTest,
    depthWrite: pass.pass.depthWrite
))
~~~

- [ ] **Step 7: Run targeted tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: PASS for six blend fixtures, culling, depth, and prior executor tests.

---

## Task 5: Add Built-In `materials/util/` Shaders

**Files:**

- Create: none
- Modify: `LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPERenderPipelineBuilderTests.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write failing builder and executor tests**

Append to `WPERenderPipelineBuilderTests.swift`.

~~~swift
extension WPERenderPipelineBuilderTests {
    @Test("Treats util material shaders as builtins")
    func treatsUtilMaterialShadersAsBuiltins() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                compositeA: "_rt_imageLayerComposite_1_a",
                compositeB: "_rt_imageLayerComposite_1_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "materials/util/solidlayer.json",
                        source: .image("models/layer.json"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_1_a"),
                        textures: [:],
                        binds: [:],
                        constants: ["g_Color": .vector([1, 1, 1, 1])],
                        combos: [:],
                        blending: "disabled",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "1.1",
                        phase: .command(file: "effects/copy/effect.json"),
                        shader: "materials/util/copy.json",
                        source: .fbo("_rt_imageLayerComposite_1_a"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_1_b"),
                        textures: [0: .fbo("_rt_imageLayerComposite_1_a")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "disabled",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "1.2",
                        phase: .command(file: "effects/compose/effect.json"),
                        shader: "materials/util/compose.json",
                        source: .fbo("_rt_imageLayerComposite_1_b"),
                        target: .scene,
                        textures: [
                            0: .fbo("_rt_imageLayerComposite_1_a"),
                            1: .fbo("_rt_imageLayerComposite_1_b")
                        ],
                        binds: [:],
                        constants: ["g_Color": .vector([1, 1, 1, 1])],
                        combos: [:],
                        blending: "disabled",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shaders = pipeline.layers.flatMap(\.passes).compactMap(\.shader)

        #expect(shaders.map(\.isBuiltin) == [true, true, true])
        #expect(shaders.map(\.name) == [
            "materials/util/solidlayer.json",
            "materials/util/copy.json",
            "materials/util/compose.json"
        ])
    }
}
~~~

Append to `WPEMetalRenderExecutorTests.swift`.

~~~swift
private extension WPEMetalRenderExecutorTests {
    @Test("solidlayer writes color multiplied by alpha")
    func solidlayerWritesColorMultipliedByAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let pass = WPERenderPass(
            id: "solidlayer.0",
            phase: .material,
            shader: "materials/util/solidlayer.json",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: ["g_Color": .vector([0, 1, 0, 0.5])],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )

        let output = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [preparedBuiltinPass(pass, uniforms: ["g_Color": .vector([0, 1, 0, 0.5])])]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r <= 5)
        #expect(abs(Int(pixel.g) - 188) <= 2)
        #expect(pixel.b <= 5)
        #expect(abs(Int(pixel.a) - 128) <= 2)
    }

    @Test("compose tints layer composites into the scene")
    func composeTintsLayerCompositesIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compositeA = "_rt_imageLayerComposite_layer_a"
        let solid = solidPass(
            id: "layer.0",
            color: [1, 1, 1, 1],
            target: .layerComposite(name: compositeA),
            blending: "disabled"
        )
        let compose = WPERenderPass(
            id: "layer.1",
            phase: .command(file: "effects/compose/effect.json"),
            shader: "materials/util/compose.json",
            source: .fbo(compositeA),
            target: .scene,
            textures: [0: .fbo(compositeA), 1: .fbo(compositeA)],
            binds: [:],
            constants: ["g_Color": .vector([0, 1, 0, 1])],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )

        let output = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [
                    preparedBuiltinPass(solid, uniforms: ["g_Color": .vector([1, 1, 1, 1])]),
                    preparedBuiltinPass(
                        compose,
                        bindings: [0: .fbo(compositeA), 1: .fbo(compositeA)],
                        uniforms: ["g_Color": .vector([0, 1, 0, 1])]
                    )
                ]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r <= 5)
        #expect(pixel.g >= 250)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }
}
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: FAIL with missing shader source or unsupported shader.

- [ ] **Step 3: Recognize util built-ins in the pipeline builder**

In `WPERenderPipelineBuilder.swift`, replace `builtinProgram(shaderName:combos:)`.

~~~swift
private func builtinProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram? {
    switch normalizedBuiltinShaderName(shaderName) {
    case "solidcolor":
        return solidColorProgram(shaderName: shaderName, combos: combos)
    case "solidlayer":
        return solidLayerProgram(shaderName: shaderName, combos: combos)
    case "copy":
        return copyProgram(shaderName: shaderName, combos: combos)
    case "compose":
        return composeProgram(shaderName: shaderName, combos: combos)
    default:
        guard isGenericImageShader(shaderName) else {
            return nil
        }
        return copyProgram(shaderName: shaderName, combos: combos)
    }
}

private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
    let lower = shaderName.lowercased()
    let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
    switch withoutJSON {
    case "solidcolor":
        return "solidcolor"
    case "solidlayer", "materials/util/solidlayer", "models/util/solidlayer":
        return "solidlayer"
    case "copy", "commands/copy", "materials/util/copy":
        return "copy"
    case "compose", "materials/util/compose":
        return "compose"
    default:
        return withoutJSON
    }
}
~~~

Add program builders.

~~~swift
private func solidLayerProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
    let vertex = """
    attribute vec3 a_Position;

    void main() {
        gl_Position = vec4(a_Position, 1.0);
    }
    """
    let fragment = """
    uniform vec4 g_Color;

    void main() {
        gl_FragColor = vec4(g_Color.rgb * g_Color.a, g_Color.a);
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

private func composeProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
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
    uniform sampler2D g_Texture1;
    uniform vec4 g_Color;
    varying vec2 v_TexCoord;

    void main() {
        vec4 a = texSample2D(g_Texture0, v_TexCoord);
        vec4 b = texSample2D(g_Texture1, v_TexCoord);
        vec4 composed = mix(a, b, b.a);
        gl_FragColor = vec4(composed.rgb * g_Color.rgb, composed.a * g_Color.a);
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

- [ ] **Step 4: Add Metal fragment functions**

In `WPEMetalBuiltins.metal`, keep `wpe_copy_fragment` and add util-specific names.

~~~metal
fragment half4 wpe_solidlayer_fragment(
    WPEVertexOut in [[stage_in]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    float alpha = saturate(uniforms.color.a);
    return half4(float4(uniforms.color.rgb * alpha, alpha));
}

fragment half4 wpe_util_copy_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return texture0.sample(linearSampler, in.uv);
}

fragment half4 wpe_compose_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 a = float4(texture0.sample(linearSampler, in.uv));
    float4 b = float4(texture1.sample(linearSampler, in.uv));
    float4 composed = mix(a, b, b.a);
    return half4(float4(composed.rgb * uniforms.color.rgb, composed.a * uniforms.color.a));
}
~~~

- [ ] **Step 5: Dispatch util built-ins in the executor**

Add a normalization helper to `WPEMetalRenderExecutor.swift`.

~~~swift
private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
    let lower = shaderName.lowercased()
    let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
    switch withoutJSON {
    case "solidcolor":
        return "solidcolor"
    case "solidlayer", "materials/util/solidlayer", "models/util/solidlayer":
        return "solidlayer"
    case "copy", "commands/copy", "materials/util/copy":
        return "copy"
    case "compose", "materials/util/compose":
        return "compose"
    default:
        if withoutJSON.hasPrefix("genericimage") {
            return "copy"
        }
        return withoutJSON
    }
}
~~~

Replace the shader dispatch in `encode(...)`.

~~~swift
switch normalizedBuiltinShaderName(pass.pass.shader) {
case "solidcolor":
    encoder.setRenderPipelineState(try renderPipeline(
        fragmentName: "wpe_solidcolor_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat
    ))
    var uniforms = WPESolidUniforms(color: colorVector(for: pass))
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

case "solidlayer":
    encoder.setRenderPipelineState(try renderPipeline(
        fragmentName: "wpe_solidlayer_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat
    ))
    var uniforms = WPESolidUniforms(color: colorVector(for: pass))
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

case "copy":
    encoder.setRenderPipelineState(try renderPipeline(
        fragmentName: pass.pass.shader == "commands/copy" ? "wpe_copy_fragment" : "wpe_util_copy_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat
    ))
    let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let texture = try resolve(
        reference: reference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    encoder.setFragmentTexture(texture, index: 0)

case "compose":
    encoder.setRenderPipelineState(try renderPipeline(
        fragmentName: "wpe_compose_fragment",
        blendMode: pass.pass.blending,
        colorPixelFormat: destination.texture.pixelFormat
    ))
    let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
    let secondReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? firstReference
    let firstTexture = try resolve(
        reference: firstReference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    let secondTexture = try resolve(
        reference: secondReference,
        textures: textures,
        frameState: frameState,
        currentTargetID: destination.id
    )
    var uniforms = WPESolidUniforms(color: colorVector(for: pass))
    encoder.setFragmentTexture(firstTexture, index: 0)
    encoder.setFragmentTexture(secondTexture, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

default:
    throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
}
~~~

- [ ] **Step 6: Run targeted tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
~~~

Expected: PASS. The two-pass `solidcolor -> compose-with-tint` acceptance fixture is now covered by `composeTintsLayerCompositesIntoScene`.

---

## Task 6: Complete Scene Integration And Acceptance Fixtures

**Files:**

- Create: none
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write failing scene integration test**

Append to `WPEMetalSceneRendererTests.swift`.

~~~swift
extension WPEMetalSceneRendererTests {
    @Test("Loads multi-pass util compose scene through Metal executor")
    func loadsMultiPassUtilComposeScene() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.utilComposeScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.renderedTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.r <= 5)
        #expect(pixel.g >= 245)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 245)
    }
}

private extension MetalSceneFixture {
    static func utilComposeScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        let effects = root.appendingPathComponent("effects/compose", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: effects, withIntermediateDirectories: true)

        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: root.appendingPathComponent("model.json"))

        try Data("""
        {
          "passes": [{
            "shader": "solidcolor",
            "constantshadervalues": { "g_Color": "1 1 1 1" },
            "blending": "disabled"
          }]
        }
        """.utf8).write(to: materials.appendingPathComponent("base.json"))

        try Data("""
        {
          "passes": [{
            "material": "materials/compose.json"
          }]
        }
        """.utf8).write(to: effects.appendingPathComponent("effect.json"))

        try Data("""
        {
          "passes": [{
            "shader": "materials/util/compose.json",
            "textures": ["_rt_imageLayerComposite_image_a", "_rt_imageLayerComposite_image_a"],
            "constantshadervalues": { "g_Color": "0 1 0 1" },
            "blending": "disabled"
          }]
        }
        """.utf8).write(to: materials.appendingPathComponent("compose.json"))

        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "image",
            "name": "Image",
            "type": "image",
            "image": "model.json",
            "effects": [{ "id": 1, "file": "effects/compose/effect.json" }]
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))

        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }
}
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected before Task 5: FAIL with unsupported util shader. Expected after Task 5 but before this task: may FAIL if `requiredTextureReferences(for:)` does not recognize util compose/copy texture needs.

- [ ] **Step 3: Update scene renderer texture discovery for util built-ins**

In `WPEMetalSceneRenderer.swift`, replace `requiredTextureReferences(for:)`.

~~~swift
private func requiredTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
    switch normalizedBuiltinShaderName(pass.pass.shader) {
    case "solidcolor", "solidlayer":
        return []

    case "copy":
        return [pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source]
            .filter(\.isExternalTextureReference)

    case "compose":
        let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
        return [first, second].filter(\.isExternalTextureReference)

    default:
        return []
    }
}

private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
    let lower = shaderName.lowercased()
    let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
    switch withoutJSON {
    case "solidcolor":
        return "solidcolor"
    case "solidlayer", "materials/util/solidlayer", "models/util/solidlayer":
        return "solidlayer"
    case "copy", "commands/copy", "materials/util/copy":
        return "copy"
    case "compose", "materials/util/compose":
        return "compose"
    default:
        if withoutJSON.hasPrefix("genericimage") {
            return "copy"
        }
        return withoutJSON
    }
}
~~~

Add this file-private extension near the bottom of the file.

~~~swift
private extension WPETextureReference {
    var isExternalTextureReference: Bool {
        switch self {
        case .image, .asset:
            return true
        case .fbo, .previous:
            return false
        }
    }
}
~~~

Keep `externalTexturePath(for:)` unchanged so it remains the final guard against accidentally loading FBOs from disk.

- [ ] **Step 4: Ensure renderer release paths are complete**

Confirm these three calls exist after Task 2:

~~~swift
executor.releaseTransientResources()
~~~

They must be present in:

- `reload()` before `load()`.
- `cleanup()`.
- `applyPerformanceProfile(.suspended)`.

Do not add any per-frame readback timer.

- [ ] **Step 5: Run the acceptance test groups**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected: PASS.

Acceptance coverage:

- Two-pass `solidcolor -> composite-with-tint`: `composeTintsLayerCompositesIntoScene`.
- FBO ping-pong checkerboard: `resolvesPreviousWithinSameFBOTarget`.
- Six blend strings: `appliesWPEBlendFactors`.
- Suspended FBO release: `suspendedProfileReleasesExecutorTransientFBOs`.

---

## Final Verification

Run the full Phase 2C verification command:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests \
  -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Then run the app/test target excluding UI tests:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -skip-testing:LiveWallpaperUITests
~~~

Expected:

- All targeted Phase 2C tests pass.
- Existing Phase 2A/2B Metal tests continue to pass.
- Swift 6 strict concurrency produces no new warnings.
- No `WPESceneDetailView` changes.
- No per-frame readback timer changes.

---

## Main Improvements

- Executor can now render real multi-pass WPE graphs instead of only `.scene` passes.
- Layer composites and declared FBOs are first-class render targets.
- Named FBO writes are readable by later passes through `.fbo(name)`.
- `.previous` supports target-local ping-pong without illegal same-texture read/write.
- FBO allocation is reusable across frames and releasable under `.suspended`.
- WPE blend/cull/depth strings affect Metal render state.
- Pipeline cache no longer conflates incompatible blend states.
- `materials/util/solidlayer.json`, `materials/util/copy.json`, and `materials/util/compose.json` have built-in Metal paths.
- Acceptance fixtures are GPU pixel tests with ±2 LSB tolerance where blending is involved.

---

## Self-Review

### Spec Coverage

- Pass target routing: covered by Task 1.
- FBO allocation/recycling, heap fallback, suspended release: covered by Task 2.
- Source resolution for `.previous` and `.fbo(name)`: covered by Tasks 1 and 3.
- Blend/cull/depth mapping and cache key: covered by Task 4.
- Built-in util shaders: covered by Task 5.
- Scene renderer integration: covered by Task 6.
- Acceptance fixtures: covered by Tasks 3, 4, 5, and 6.
- Out-of-scope exclusions: explicitly preserved in Scope and Final Verification.

### Placeholder Scan

This plan contains concrete files, tests, commands, and implementation snippets. It does not require unspecified dependencies or unowned UI work.

### Type Consistency

- `WPEMetalTargetID`, `WPEMetalFrameState`, and `WPEMetalRenderTargetPool` are used consistently by `WPEMetalRenderExecutor`.
- `WPEMetalPipelineKey` replaces the prior `String` pipeline key.
- `WPESolidUniforms` is reused for `solidcolor`, `solidlayer`, and `compose` tint uniforms.
- Existing public renderer APIs remain unchanged.

### Residual Risk

- `normalmapped` is mapped to `normal` until translated shaders prove a different WPE convention.
- `unique` FBO semantics may need a follow-up if real Workshop scenes reuse the same unique FBO name across independent layers.
- Previous-frame feedback remains deliberately unsupported; this plan implements intra-frame `previous` only.
