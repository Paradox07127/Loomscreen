#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit

/// Shared classifier for WPE compose/project utility layers, so the dispatcher,
/// target pool, and executor branch on one definition instead of duplicating
/// path checks.
enum WPEMetalSceneCaptureUtilityModels {
    /// WPE `fullscreen`/`passthrough` utility models — `composelayer.json`,
    /// `projectlayer.json`, and `fullscreenlayer.json` (the post-process /
    /// depth-of-field carrier) — all capture the full frame and MUST render
    /// fullscreen with a scene-sized composite. Drawing them at their authored
    /// object footprint shrinks the result into a "picture-in-picture" panel
    /// (e.g. scene 3479521040's DoF layer was a `fullscreenlayer`). Tolerates a
    /// leading `../<dependencyID>/` resolver prefix.
    static func isSceneCaptureUtilityModelPath(_ path: String) -> Bool {
        let stripped = strippedUtilityPath(path)
        return stripped == "models/util/composelayer.json"
            || stripped == "models/util/projectlayer.json"
            || stripped == "models/util/fullscreenlayer.json"
    }

    /// Output geometry for a scene-capture utility (passthrough) layer's FINAL
    /// scene composite. The capture / `previous` sampling always stays
    /// full-frame 1:1 (the 98f79b5 lesson); only the output composite of a
    /// plain `composelayer.json` that hosts a *spatial* effect authored into a
    /// real sub-rect (e.g. an audio-bar visualizer box) is confined to that box.
    enum OutputGeometry { case fullscreen, subregion }

    /// `fullscreenlayer.json` (DoF/post-process) and `projectlayer.json`
    /// (projection/autosize) always cover the frame. A `composelayer.json`
    /// stays fullscreen too unless its authored footprint is a safe sub-scene
    /// rectangle: axis-aligned, positive-scale, finite, and clearly smaller
    /// than the scene. Rotated / mirrored / oversized / full-coverage compose
    /// layers stay fullscreen — this preserves 98f79b5's decision for scene
    /// 3479521040's 5000×2300 rotated passthrough layer.
    static func outputGeometry(
        path: String,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> OutputGeometry {
        guard strippedUtilityPath(path) == "models/util/composelayer.json" else { return .fullscreen }
        guard let size = geometry.size else { return .fullscreen }
        let sceneW = max(Float(sceneSize.width), 1)
        let sceneH = max(Float(sceneSize.height), 1)
        let width = Float(size.width) * max(abs(Float(geometry.scale.x)), 0.0001)
        let height = Float(size.height) * max(abs(Float(geometry.scale.y)), 0.0001)
        guard width.isFinite, height.isFinite, width > 1, height > 1 else { return .fullscreen }
        let rotationEpsilon = 0.001
        if abs(geometry.angles.x) > rotationEpsilon
            || abs(geometry.angles.y) > rotationEpsilon
            || abs(geometry.angles.z) > rotationEpsilon {
            return .fullscreen
        }
        if geometry.scale.x < 0 || geometry.scale.y < 0 { return .fullscreen }
        let fullCoverage: Float = 0.95
        if width >= sceneW * fullCoverage && height >= sceneH * fullCoverage { return .fullscreen }
        return .subregion
    }

    private static func strippedUtilityPath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if normalized.hasPrefix("../") {
            let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count >= 3 ? parts.dropFirst(2).joined(separator: "/") : normalized
        }
        return normalized
    }
}

final class WPEMetalRenderExecutor {
    /// Phase 2A H3: every offscreen target and the on-screen swapchain share
    /// a single sRGB pixel format so render pipelines built for the offscreen
    /// pass can be reused by `present()` without re-creation, and so the
    /// rendered gamma stays stable across offscreen and onscreen passes.
    static let outputPixelFormat: MTLPixelFormat = .rgba8Unorm_srgb

    /// Debug bisect flag: when `defaults write Taijia.LiveWallpaper
    /// WPEMetalBypassEffects -bool YES` is in effect (and the binary is
    /// a DEBUG build) every image layer skips its material/effect/command
    /// passes and blits the first pass's resolved source texture to scene.
    /// Used to confirm Metal's upload+present chain reaches the screen
    /// before the effect shader chain is exercised. Always false in
    /// Release builds.
    static var bypassEffectsForDebug: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "WPEMetalBypassEffects")
        #else
        return false
        #endif
    }

    /// Prototype flag: defer the puppet mesh warp from the base material pass to
    /// the final scene composite, so the base image + entire effect chain run in
    /// puppet atlas/local UV space (effect masks align with the mesh). Default-off
    /// and DEBUG-only so Release builds stay byte-identical while the core puppet
    /// pipeline is validated. Enable: `defaults write Taijia.LiveWallpaper
    /// WPEPuppetDeferMeshWarp -bool YES`.
    static var deferPuppetMeshWarp: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "WPEPuppetDeferMeshWarp")
        #else
        return false
        #endif
    }

    /// Diagnostic: log each puppet's GPU-skinning gate result (enabled, or the
    /// disable reason — `unresolved-attachment` / `missing-hierarchy` /
    /// `palette-unresolved` / `skin-index-out-of-range` / `palette-unbounded` /
    /// `no-animation` / `user-disabled`). A gated-off puppet falls back to the
    /// static rest pose (no blink/sway), so this surfaces *why* a puppet doesn't
    /// animate. Logged once per object per change (not per frame). DEBUG-only.
    /// Enable: `defaults write Taijia.LiveWallpaper WPEPuppetLogSkinningReason -bool YES`.
    static var logPuppetSkinningReason: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "WPEPuppetLogSkinningReason")
        #else
        return false
        #endif
    }

    /// Rollback gate for sub-region compose-layer output (the audio-visualizer
    /// "box" fix). Default ON. `defaults write Taijia.LiveWallpaper
    /// WPEMetalSubregionComposeOutput -bool NO` reverts every scene-capture
    /// utility layer to the legacy unconditional-fullscreen output.
    static var subregionComposeOutputEnabled: Bool {
        UserDefaults.standard.object(forKey: "WPEMetalSubregionComposeOutput") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "WPEMetalSubregionComposeOutput")
    }

    /// Mirrors the slot-0 precedence used by
    /// `WPEMetalSceneRenderer.requiredTextureReferences(for:)`: prefer the
    /// per-pass binding override, then the pass's `textures[0]`, then the
    /// raw graph source. We use this to look up the layer's resolved
    /// background image in the bypass path so the blit copies the asset
    /// the renderer actually preloaded — not the unresolved model JSON
    /// path that `WPERenderLayer.imagePath` carries.
    static func bypassSourceReference(for layer: WPEPreparedRenderLayer) -> WPETextureReference? {
        guard let firstPass = layer.passes.first else { return nil }
        return firstPass.textureBindings[0]
            ?? firstPass.pass.textures[0]
            ?? firstPass.pass.source
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let targetPool: WPEMetalRenderTargetPool
    private let depthCache: WPEMetalDepthStateCache
    private let pipelineCache: WPEMetalPipelineCache
    /// Invoked when the dispatcher sees a non-built-in shader. Defaults to
    /// the shipping Swift transpiler; tests inject an alternate compiler at
    /// this seam.
    let shaderCompiler: WPEShaderCompiling
    /// Phase 2D-H: memoize the per-shader compile across frames so we
    /// don't re-translate every draw call.
    private var translatedShaderCache: [String: WPEShaderCompileResult] = [:]
    /// Phase 2D-H: cache MTLRenderPipelineState built from translated
    /// shaders. Library + blend + format set is the key.
    private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]
    private var previousFrameHistory: PreviousFrameHistory?
    private var msdfTextPipelineCache: [MSDFTextPipelineKey: MTLRenderPipelineState] = [:]
    private var msdfNeutralWhiteTexture: MTLTexture?

    private struct MSDFTextPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let colorPixelFormat: UInt
    }

    /// Per-puppet skinning decision for the current frame. `enabled` is false (and `palette` empty)
    /// whenever the validation gate rejects skinning, so the pass renders the static assembled mesh.
    private struct PuppetSkinningState {
        let enabled: Bool
        let palette: [simd_float4x4]
        let attachmentsByName: [String: WPEPuppetAttachment]
        /// Parent puppet's MDLS bind matrices (model space) keyed by bone index, for anchor following.
        let boneBindByIndex: [Int: simd_float4x4]
        let reason: String
    }

    /// Per-frame attachment/skinning context, built once before the layer loop so a parent puppet's
    /// animated bone palette is available before its attached children render.
    private struct PuppetAttachmentFrameContext {
        let layersByObjectID: [String: WPEPreparedRenderLayer]
        let skinningByObjectID: [String: PuppetSkinningState]
        let sceneSize: CGSize
    }

    private struct PreviousFrameHistory {
        let sceneSize: CGSize
        let sceneTexture: MTLTexture?
        let namedTextures: [String: MTLTexture]
    }

    private struct TranslatedPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let vertexName: String
        let fragmentName: String
        let blendMode: String
        let colorPixelFormat: UInt
        let depthPixelFormat: UInt
    }

    init(device: MTLDevice, shaderCompiler: WPEShaderCompiling? = nil) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderExecutorError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderExecutorError.libraryUnavailable
        }
        self.device = device
        commandQueue = queue
        self.targetPool = WPEMetalRenderTargetPool(device: device)
        self.depthCache = WPEMetalDepthStateCache(device: device)
        self.pipelineCache = WPEMetalPipelineCache(device: device, library: library)
        self.shaderCompiler = shaderCompiler ?? Self.preferredCompiler(device: device)
    }

    private static func preferredCompiler(device: MTLDevice) -> any WPEShaderCompiling {
        // The Swift transpiler is the only Metal-side translator we ship.
        // Shaders it can't handle bubble up as
        // `WPEMetalRenderExecutorError.shaderTranslatorUnavailable`.
        WPESwiftShaderCompiler(device: device)
    }

    /// Phase 2E: lets `WPEMetalSceneRenderer` hand the executor's MTLDevice
    /// to `WPEVideoTextureSource` (which needs it to build a
    /// `CVMetalTextureCache`) without exposing the device publicly.
    var textureSourceDevice: MTLDevice {
        device
    }

    func releaseTransientResources() {
        targetPool.releaseAll()
        previousFrameHistory = nil
    }

    /// One-shot guard so the waterwaves dispatch logs its first live execution per renderer
    /// (confirms the builtin effect_waterwaves path actually runs + the debug flag value reaching it).
    private var loggedWaterWavesDispatch = false
    /// Scene size (ortho-projection pixels) for the frame currently encoding.
    /// Stashed at frame start so `usesObjectQuadGeometry` can judge a
    /// scene-capture utility layer's footprint without threading `sceneSize`
    /// through its dozen call sites. Safe because the render loop encodes one
    /// frame at a time.
    private var currentSceneSize: CGSize = .zero
    /// Diagnostic dedupe for the compose-subregion box (one log per object per
    /// executor lifetime). Temporary — remove once the audio-box path is proven.
    private var loggedSubregionDiag: Set<String> = []

    #if DEBUG
    /// Diagnostic: when `WPEDumpScenePasses` (UserDefault) equals the sceneID,
    /// holds one snapshot of the scene output after EACH scene-target pass so
    /// `WPEMetalSceneRenderer` can PNG-dump them and localize which pass draws
    /// a given artifact. Memory-bounded — cleared at the start of every render().
    private(set) var scenePassDumps: [(label: String, texture: MTLTexture)] = []
    /// Diagnostic: when `WPEDumpLayerPasses` (UserDefault) equals a layer
    /// objectID, snapshot that ONE layer's destination texture after EVERY
    /// pass (base image + each effect FBO), so we can localize which pass on a
    /// single puppet/layer introduces an artifact. Scoped to one object to
    /// stay memory-safe (capturing every pass scene-wide would OOM the GPU).
    private var dumpLayerPassesID: String?
    #endif

    func render(
        pipeline: WPEPreparedRenderPipeline,
        size: CGSize,
        textures: [String: MTLTexture],
        runtimeUniforms: WPEMetalRuntimeUniforms = .zero,
        cameraUniforms: WPEMetalCameraUniforms = .identity,
        sceneID: String? = nil
    ) throws -> MTLTexture {
        #if DEBUG
        scenePassDumps.removeAll()
        let dumpScenePasses = sceneID.map { !$0.isEmpty && UserDefaults.standard.string(forKey: "WPEDumpScenePasses") == $0 } ?? false
        dumpLayerPassesID = {
            let id = UserDefaults.standard.string(forKey: "WPEDumpLayerPasses")
            return (id?.isEmpty == false) ? id : nil
        }()
        #endif
        let preparedPipeline = pipeline.addingMetalRuntimeUniforms(runtimeUniforms, camera: cameraUniforms)
        let output = try makeOutputTexture(size: size)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        let reusableHistory: PreviousFrameHistory?
        if let history = previousFrameHistory, history.sceneSize == size {
            reusableHistory = history
        } else {
            reusableHistory = nil
            previousFrameHistory = nil
        }

        targetPool.prepare(pipeline: preparedPipeline)
        // The per-frame output texture is freshly allocated and `.shared`; its
        // backing store is NOT zeroed by Metal. A scene-alias read of
        // `_rt_FullFrameBuffer` before any scene-target pass writes (e.g.
        // shine_combine's COPYBG, which samples the full-frame buffer while
        // still rendering into a layer composite) would otherwise sample this
        // garbage and, with shine's `albedo.a = saturate(albedo.a + rays.a)`
        // accumulation, ramp the whole layer to white within a few seconds.
        // Clear to the scene clear color so any pre-write alias read sees black.
        try clearTexture(output, color: clearColor(for: .scene), commandBuffer: commandBuffer)
        var frameState = WPEMetalFrameState(
            output: output,
            sceneSize: size,
            previousSceneTexture: reusableHistory?.sceneTexture,
            previousNamedTextures: reusableHistory?.namedTextures ?? [:]
        )
        frameState.cameraParallax = runtimeUniforms.cameraParallax
        currentSceneSize = size
        var didEncode = false
        let bypassEffects = Self.bypassEffectsForDebug
        let attachmentContext = makeAttachmentFrameContext(
            for: preparedPipeline,
            runtimeUniforms: runtimeUniforms,
            sceneSize: size
        )

        for layer in preparedPipeline.layers {
            // Attached children (face/hair on a body-split rig) follow the parent puppet's animated
            // anchor bone; `graphLayer` carries the followed transform, falling back to the static
            // layer when there is no resolved attachment. Skinning is validated/cached once per frame.
            let graphLayer = layerApplyingAttachmentFollow(layer.graphLayer, context: attachmentContext)
            let skinningState = attachmentContext.skinningByObjectID[layer.graphLayer.objectID]
            if layer.passes.isEmpty {
                // Hidden plain-image layer: nothing composites elsewhere, so
                // simply skip the scene blit. `didEncode` stays satisfied so an
                // all-hidden scene renders empty instead of erroring.
                guard layer.graphLayer.visible else {
                    didEncode = true
                    continue
                }
                try encodeCopy(
                    reference: .image(layer.graphLayer.imagePath),
                    target: .scene,
                    layer: graphLayer,
                    runtimeUniforms: runtimeUniforms,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    frameState: &frameState
                )
                didEncode = true
                #if DEBUG
                captureScenePassIfDumping(dumpScenePasses, label: "\(layer.graphLayer.objectID).image", output: output, commandBuffer: commandBuffer)
                #endif
                continue
            }
            if bypassEffects, let firstSource = Self.bypassSourceReference(for: layer) {
                guard graphLayer.visible else {
                    didEncode = true
                    continue
                }
                // Debug bisect: skip every material/effect/command pass and
                // blit the first pass's resolved source (the background
                // image) straight to scene. Lets us prove the upload +
                // present chain works at the layer's native resolution
                // before the effect shaders join the mix. Debug-only path, so
                // a layer whose first source isn't a sampleable texture (e.g. a
                // solidlayer/util color layer whose source is `models/util/
                // solidlayer.json`) is skipped rather than aborting the whole
                // scene with a RESOURCE_MISS.
                do {
                    try encodeCopy(
                        reference: firstSource,
                        target: .scene,
                        layer: graphLayer,
                        runtimeUniforms: runtimeUniforms,
                        textures: textures,
                        commandBuffer: commandBuffer,
                        frameState: &frameState
                    )
                } catch {
                    Logger.warning(
                        "[WPE.bypass] skipped layer \(layer.graphLayer.objectID): source \(firstSource) not blittable (\(error))",
                        category: .wpeRender
                    )
                }
                didEncode = true
                continue
            }
            for pass in layer.passes {
                // Hidden layer: still encode passes that write a composite/FBO
                // (dependents may sample them), but skip the final scene draw so
                // the layer is invisible. Toggling `visible` true re-includes it
                // without a pipeline rebuild.
                if !graphLayer.visible {
                    switch pass.pass.target {
                    case .scene:
                        didEncode = true
                        continue
                    case .layerComposite, .fbo:
                        break
                    }
                }
                try encode(
                    pass: pass,
                    layer: graphLayer,
                    puppetModel: layer.puppetModel,
                    skinningState: skinningState,
                    runtimeUniforms: runtimeUniforms,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    frameState: &frameState
                )
                didEncode = true
                #if DEBUG
                if case .scene = pass.pass.target {
                    captureScenePassIfDumping(dumpScenePasses, label: pass.pass.id, output: output, commandBuffer: commandBuffer)
                }
                #endif
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
        previousFrameHistory = PreviousFrameHistory(
            sceneSize: size,
            sceneTexture: frameState.latestSceneTexture,
            // Carry ONLY targets actually read back via cross-frame `.previous`
            // (persistent feedback). Scene aliases and effect scratch buffers
            // (`_rt_HalfCompoBuffer*` etc.) are recomputed every frame and must
            // not persist, or the shine chain ramps the layer white over ~5s.
            // Do NOT carry named FBOs across frames. They are per-frame scratch
            // (`_rt_HalfCompoBuffer*` shine cast/gaussian) or same-frame ping-pong
            // composites (`_rt_imageLayerComposite_*`), none of which represent
            // last-frame state. Carrying them let the shine chain re-blend its
            // own previous output and, via `saturate(albedo.a + rays.a)`, ramp
            // the whole layer to white within ~5s (scene 3526278753).
            // Cross-frame scene feedback still works through `sceneTexture` above.
            // A precise "carry only `.previous`-read targets" filter was tried and
            // REGRESSED: effect-bind `{name:"previous"}` lowers to the SAME
            // `.previous` token as true cross-frame feedback, so it mis-carried
            // the shine composite and the white-out returned. Empty carry is the
            // verified-correct behavior; revisit only if a real persistent-trail
            // effect needs named-target history (none in the corpus today).
            namedTextures: [:]
        )
        return output
    }

    /// Phase 2D-L: render every alive particle system on top of the supplied output texture.
    func drawParticles(
        systems: [WPEParticleSystem],
        texturesByMaterial: [ObjectIdentifier: MTLTexture],
        sceneSize: CGSize,
        output: MTLTexture,
        cameraParallax: WPECameraParallaxFrame = .neutral
    ) throws {
        let alive = systems.filter { $0.liveInstanceCount > 0 }
        guard !alive.isEmpty else { return }

        // Resolve per-system pipeline states (throwing) BEFORE opening the encoder,
        // so a failure can't dealloc an encoder without endEncoding (Metal asserts
        // "Command encoder released without endEncoding").
        let draws: [(system: WPEParticleSystem, texture: MTLTexture, state: MTLRenderPipelineState)] =
            try alive.compactMap { system in
                // Systems whose texture failed to load were filtered at scene-load;
                // skip defensively so a stale texture-slot binding can't leak in.
                guard let texture = texturesByMaterial[ObjectIdentifier(system)] else { return nil }
                let state = try particlePipelineState(colorPixelFormat: output.pixelFormat, blendMode: system.blendMode)
                return (system, texture, state)
            }
        guard !draws.isEmpty else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        var projection = WPEParticleProjection(
            sceneSize: SIMD4<Float>(
                Float(max(sceneSize.width, 1)),
                Float(max(sceneSize.height, 1)),
                0, 0
            )
        )

        for draw in draws {
            let system = draw.system
            let texture = draw.texture
            encoder.setRenderPipelineState(draw.state)
            // Translate the whole system by its camera-parallax depth (pixels),
            // carried in `padding.xy` and added to each particle's screen
            // position in the vertex shader.
            let parallax = cameraParallax.pixelOffset(depth: system.parallaxDepth, sceneSize: sceneSize)
            projection.padding = SIMD4<Float>(parallax.x, parallax.y, 0, 0)
            encoder.setVertexBuffer(system.instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 2)
            var sprite = WPEParticleSpriteParams(grid: SIMD4<Float>(
                Float(system.spriteSheet?.cols ?? 1),
                Float(system.spriteSheet?.rows ?? 1),
                Float(system.spriteSheet?.frameCount ?? 1),
                (system.spriteSheet?.isAlphaMask ?? false) ? 1 : 0
            ))
            encoder.setVertexBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 3)
            encoder.setFragmentBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: system.liveInstanceCount
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Mirrors `WPEParticleSpriteParams` in `WPEMetalBuiltins.metal` —
    /// `grid.xy = (cols, rows)`, `grid.z = frameCount` (loop modulo),
    /// `grid.w = 1` flags an r8 alpha-mask atlas (fog particles) so the
    /// fragment shader pulls colour from the per-particle tint and uses
    /// the texture sample only as the opacity.
    struct WPEParticleSpriteParams {
        var grid: SIMD4<Float>
    }

    /// Phase 2D-N: composite a list of pre-rasterized text overlays on top of the supplied output texture.
    func drawTextOverlays(
        overlays: [WPETextOverlayDraw],
        sceneSize: CGSize,
        output: MTLTexture
    ) throws {
        guard !overlays.isEmpty else { return }
        // Resolve the pipeline (can throw) BEFORE opening the encoder, so a
        // failure never leaks an encoder without endEncoding (Metal asserts
        // "Command encoder released without endEncoding").
        let state = try textOverlayPipelineState(colorPixelFormat: output.pixelFormat)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(state)

        for overlay in overlays {
            var u = WPETextOverlayUniforms(
                centerAndSize: SIMD4<Float>(
                    Float(overlay.centerInScenePixels.x),
                    Float(overlay.centerInScenePixels.y),
                    Float(overlay.sizeInScenePixels.width),
                    Float(overlay.sizeInScenePixels.height)
                ),
                sceneSize: SIMD4<Float>(
                    Float(max(sceneSize.width, 1)),
                    Float(max(sceneSize.height, 1)),
                    0, 0
                ),
                color: SIMD4<Float>(
                    overlay.tint.x,
                    overlay.tint.y,
                    overlay.tint.z,
                    overlay.alpha
                )
            )
            encoder.setFragmentTexture(overlay.texture, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<WPETextOverlayUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<WPETextOverlayUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Draw GPU MSDF text: compile the translated `font.frag` (cached per combo
    /// set), bind per-page glyph quads + atlas texture, pack the font material
    /// uniforms by slot, and composite with premultiplied alpha onto `output`.
    func drawMSDFText(
        payloads: [WPEMSDFTextDrawPayload],
        sceneSize: CGSize,
        output: MTLTexture
    ) throws {
        guard !payloads.isEmpty else { return }

        // Resolve everything that can THROW (white texture, font.frag compile,
        // pipeline state) BEFORE opening the render encoder. A failure here (e.g.
        // a font.frag combo that won't translate) then throws with no encoder
        // open, so the scene renderer can catch it and fall back to CoreText.
        // Doing these `try`s after makeRenderCommandEncoder would dealloc the
        // encoder without endEncoding → Metal asserts
        // ("Command encoder released without endEncoding") and crashes.
        let whiteTexture = try msdfWhiteTexture()
        let prepared: [(state: MTLRenderPipelineState, result: WPEShaderCompileResult, payload: WPEMSDFTextDrawPayload)] =
            try payloads.map { payload in
                let result = try compileMSDFFontShader(payload.shaderRequest)
                let state = try msdfTextPipelineState(for: result, colorPixelFormat: output.pixelFormat)
                return (state: state, result: result, payload: payload)
            }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        var sceneSizeValue = SIMD2<Float>(
            Float(max(sceneSize.width, 1)),
            Float(max(sceneSize.height, 1))
        )
        // From here on there are NO throwing calls until endEncoding().
        for item in prepared {
            encoder.setRenderPipelineState(item.state)
            encoder.setVertexBytes(&sceneSizeValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

            for page in item.payload.pages {
                encoder.setVertexBuffer(page.vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(page.texture, index: 0)
                encoder.setFragmentTexture(whiteTexture, index: 1)
                var slots = packTranslatedUniforms(
                    values: item.payload.uniforms,
                    layout: item.result.uniformLayout,
                    texturesBySlot: [0: page.texture, 1: whiteTexture],
                    destinationTexture: output
                )
                encoder.setFragmentBytes(
                    &slots,
                    length: MemoryLayout<SIMD4<Float>>.stride * slots.count,
                    index: 0
                )
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: page.vertexCount)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func compileMSDFFontShader(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        if let cached = translatedShaderCache[request.translationCacheKey] {
            return cached
        }
        let result = try shaderCompiler.compile(request)
        translatedShaderCache[request.translationCacheKey] = result
        return result
    }

    private func msdfTextPipelineState(
        for result: WPEShaderCompileResult,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let key = MSDFTextPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            colorPixelFormat: colorPixelFormat.rawValue
        )
        if let cached = msdfTextPipelineCache[key] {
            return cached
        }
        guard let vertex = device.makeDefaultLibrary()?.makeFunction(name: "wpe_msdf_text_vertex"),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        guard let attachment = pipelineDescriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // font.frag returns STRAIGHT (non-premultiplied) alpha — vec4(rgb, a) —
        // so source RGB must be scaled by sourceAlpha. Using .one (premultiplied)
        // over-contributed RGB and haloed semi-transparent text / AA edges.
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        msdfTextPipelineCache[key] = state
        return state
    }

    private func msdfWhiteTexture() throws -> MTLTexture {
        if let msdfNeutralWhiteTexture { return msdfNeutralWhiteTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_msdf_text_white_texture")
        }
        texture.label = "WPE MSDF neutral white"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        var pixel: UInt32 = 0xFFFF_FFFF
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        msdfNeutralWhiteTexture = texture
        return texture
    }

    /// Packs a `[name: value]` uniform dictionary into the translated shader's
    /// `WPEUniforms.vals[]` array by the slot indices from its uniform layout.
    /// Mirrors the per-pass packer but takes a standalone values dict (used by
    /// the MSDF text path, which builds uniforms outside the render graph).
    func packTranslatedUniforms(
        values: [String: WPESceneShaderConstantValue],
        layout: [WPEUniformSlot],
        texturesBySlot: [Int: MTLTexture] = [:],
        destinationTexture: MTLTexture? = nil
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: WPEShaderTranspiler.uniformSlotMaximum)
        for u in layout {
            guard u.slot < slots.count else { continue }
            let value = Self.textureResolutionValue(
                named: u.name,
                texturesBySlot: texturesBySlot,
                destinationTexture: destinationTexture
            ) ?? Self.firstValue(
                in: values,
                matching: Self.translatedUniformNameCandidates(for: u)
            ) ?? u.defaultValue
            if let length = u.arrayLength {
                Self.packArrayUniform(value, glslType: u.glslType, length: length, slot: u.slot, into: &slots)
                continue
            }
            switch u.glslType {
            case "vec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
            default:
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            }
        }
        return slots
    }

    private var textOverlayPipelineCache: [UInt: MTLRenderPipelineState] = [:]

    private func textOverlayPipelineState(colorPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = textOverlayPipelineCache[colorPixelFormat.rawValue] {
            return cached
        }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "wpe_text_overlay_vertex"),
              let fragment = library.makeFunction(name: "wpe_text_overlay_fragment") else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_overlay_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_overlay_fragment")
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        textOverlayPipelineCache[colorPixelFormat.rawValue] = state
        return state
    }

    private struct ParticlePipelineKey: Hashable {
        let pixelFormat: UInt
        let blendMode: WPEParticleBlendMode
    }

    private var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]

    private func particlePipelineState(
        colorPixelFormat: MTLPixelFormat,
        blendMode: WPEParticleBlendMode
    ) throws -> MTLRenderPipelineState {
        let key = ParticlePipelineKey(pixelFormat: colorPixelFormat.rawValue, blendMode: blendMode)
        if let cached = particlePipelineCache[key] {
            return cached
        }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "wpe_particle_vertex"),
              let fragment = library.makeFunction(name: "wpe_particle_instanced_fragment") else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_particle_instanced_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_particle_instanced_fragment")
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // Fragment shader outputs straight (non-premultiplied) alpha. WPE
        // material `blending` strings map to the three classic factor
        // combos — anything else falls back to translucent at parse time.
        switch blendMode {
        case .normal:
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .zero
        case .translucent:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .one
        }
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        particlePipelineCache[key] = state
        return state
    }

    @MainActor
    func present(texture source: MTLTexture, in view: MTKView) throws -> Bool {
        guard let drawable = view.currentDrawable else {
            #if DEBUG
            Logger.warning(
                "[present] view.currentDrawable=nil — source=\(source.width)x\(source.height) view.bounds=\(view.bounds) drawableSize=\(view.drawableSize)",
                category: .wpeRender
            )
            #endif
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let copyState = try renderPipeline(
            fragmentName: "wpe_copy_fragment",
            blendMode: "disabled",
            colorPixelFormat: drawable.texture.pixelFormat
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(copyState)
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = WPECopyUniforms(uvOffset: SIMD2<Float>(0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        #if DEBUG
        // Keep only the error case; the per-frame "completed" line spammed the log.
        commandBuffer.addCompletedHandler { cb in
            if cb.status == .error {
                Logger.warning(
                    "[present] commandBuffer ERROR after present: \(cb.error?.localizedDescription ?? "unknown")",
                    category: .wpeRender
                )
            }
        }
        #endif
        commandBuffer.commit()
        return true
    }

    private func clearColor(for targetID: WPEMetalTargetID) -> MTLClearColor {
        switch targetID {
        case .scene:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .named:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    /// Whether a pass should `.load` the existing attachment contents instead of
    /// `.clear`ing. A ping-pong composite's physical texture is reused across
    /// passes, so a later source-over pass writing the SAME named target would
    /// otherwise blend over an earlier logical pass's stale result (the
    /// hair/staff "double displacement" ghost). Only load when the contents are
    /// genuinely needed: a self/previous-target read (feedback), the scene
    /// framebuffer (layer compositing), or an accumulation blend.
    private func shouldLoadExistingAttachment(
        for pass: WPEPreparedRenderPass,
        targetID: WPEMetalTargetID,
        destinationTexture: MTLTexture,
        readsCurrentTarget: Bool,
        frameState: WPEMetalFrameState
    ) -> Bool {
        guard frameState.hasInitialized(destinationTexture) else {
            return false
        }
        if readsCurrentTarget {
            return true
        }
        if case .scene = targetID {
            return true
        }
        return blendModeRequiresExistingDestination(pass.pass.blending)
    }

    private func blendModeRequiresExistingDestination(_ blendMode: String) -> Bool {
        let normalized = blendMode
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "add",
             "additive",
             "premultipliedadditive",
             "premultipliedmultiply",
             "darken",
             "lighten",
             "multiply",
             "negative",
             "oneone",
             "oneoneone",
             "subtract",
             "subtractive":
            return true
        default:
            return false
        }
    }

    private func encode(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: pass.pass.target)
        let initialPreviousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = passReadsCurrentTarget(pass, targetID: targetID)
        let destination = try targetTexture(
            for: pass.pass.target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? initialPreviousTextureForTarget : nil
        )

        #if DEBUG
        // Per-pass FBO isolation for one layer: snapshot this pass's destination
        // after the draw (function-scope defer runs at encode() exit) so we can
        // see exactly which pass on the layer introduces an artifact.
        let shouldDumpLayerPass = dumpLayerPassesID != nil && layer.objectID == dumpLayerPassesID
        defer {
            if shouldDumpLayerPass {
                captureScenePassIfDumping(
                    true,
                    label: "L\(layer.objectID)-\(pass.pass.id)",
                    output: destination.texture,
                    commandBuffer: commandBuffer
                )
            }
        }
        #endif

        try snapshotFullFrameBufferIfAliasingScene(
            pass: pass,
            destinationTexture: destination.texture,
            targetID: targetID,
            layer: layer,
            commandBuffer: commandBuffer,
            frameState: &frameState
        )

        let previousTextureForTarget: MTLTexture?
        if readsCurrentTarget {
            previousTextureForTarget = try previousTextureForRead(
                targetID: targetID,
                matching: destination.texture,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
        } else {
            previousTextureForTarget = initialPreviousTextureForTarget
        }

        if readsCurrentTarget,
           let previousTextureForTarget,
           ObjectIdentifier(previousTextureForTarget) != ObjectIdentifier(destination.texture),
           !frameState.hasInitialized(destination.texture) {
            try copyTexture(
                previousTextureForTarget,
                to: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(destination.texture)
        }

        let needsDepth = depthCache.needsAttachment(for: pass)

        let shouldLoadExistingAttachment = shouldLoadExistingAttachment(
            for: pass,
            targetID: targetID,
            destinationTexture: destination.texture,
            readsCurrentTarget: readsCurrentTarget,
            frameState: frameState
        )

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = shouldLoadExistingAttachment ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor(for: targetID)

        if needsDepth {
            let depth = try depthCache.attachmentTexture(for: destination, frameState: &frameState)
            descriptor.depthAttachment.texture = depth
            descriptor.depthAttachment.loadAction = shouldLoadExistingAttachment ? .load : .clear
            descriptor.depthAttachment.storeAction = .store
            descriptor.depthAttachment.clearDepth = 1
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(WPEMetalPipelineCache.cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthCache.stencilState(
            depthTest: pass.pass.depthTest,
            depthWrite: pass.pass.depthWrite
        ))

        let drewPuppetMaterial = try encodePuppetMaterialPassIfNeeded(
            pass: pass,
            layer: layer,
            puppetModel: puppetModel,
            skinningState: skinningState,
            runtimeUniforms: runtimeUniforms,
            destination: destination,
            textures: textures,
            frameState: frameState,
            encoder: encoder,
            depthPixelFormat: needsDepth ? .depth32Float : .invalid
        )
        let drewPuppetSceneComposite: Bool
        if drewPuppetMaterial {
            drewPuppetSceneComposite = false
        } else {
            drewPuppetSceneComposite = try encodePuppetSceneCompositePassIfNeeded(
                pass: pass,
                layer: layer,
                puppetModel: puppetModel,
                skinningState: skinningState,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )
        }
        if !drewPuppetMaterial && !drewPuppetSceneComposite {
            let dispatcher = WPEMetalShaderDispatcher(executor: self)
            try dispatcher.dispatch(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Resolves the object's visible animation layers into evaluator layers. The scene can stack
    /// several (e.g. a base idle-sway layer + an ADDITIVE blink/face layer); we play them all so
    /// blinks/mouth motion compose on top of the body sway, instead of only the first layer.
    private func puppetAnimationLayers(
        for layer: WPERenderLayer,
        model: WPEPuppetModel
    ) -> [WPEPuppetAnimationLayer] {
        guard !layer.animationLayers.isEmpty else {
            return model.animations.first.map {
                [WPEPuppetAnimationLayer(animation: $0, rate: 1, additive: false, blend: 1)]
            } ?? []
        }
        return layer.animationLayers.compactMap { sceneLayer in
            guard sceneLayer.visible,
                  let animation = model.animations.first(where: { $0.id == sceneLayer.animation }) else {
                return nil
            }
            return WPEPuppetAnimationLayer(
                animation: animation,
                rate: sceneLayer.rate > 0 ? sceneLayer.rate : 1,
                additive: sceneLayer.additive,
                blend: Float(sceneLayer.blend)
            )
        }
    }

    /// Validates skinning for every puppet and caches each parent's animated palette once, so an
    /// attached child can read its parent's anchor-bone transform before the child itself renders.
    private func makeAttachmentFrameContext(
        for pipeline: WPEPreparedRenderPipeline,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        sceneSize: CGSize
    ) -> PuppetAttachmentFrameContext {
        let layersByID = Dictionary(
            pipeline.layers.map { ($0.graphLayer.objectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var attachedChildNamesByParent: [String: Set<String>] = [:]
        for layer in pipeline.layers {
            guard let parentID = layer.graphLayer.parentObjectID,
                  let attachment = layer.graphLayer.attachment else { continue }
            attachedChildNamesByParent[parentID, default: []].insert(attachment)
        }
        var skinningByObjectID: [String: PuppetSkinningState] = [:]
        for layer in pipeline.layers {
            guard let model = layer.puppetModel else { continue }
            skinningByObjectID[layer.graphLayer.objectID] = validatedSkinningState(
                for: layer.graphLayer,
                model: model,
                attachedChildNames: attachedChildNamesByParent[layer.graphLayer.objectID] ?? [],
                runtimeUniforms: runtimeUniforms
            )
        }
        #if DEBUG
        if Self.logPuppetSkinningReason {
            logResolvedPuppetSkinning(pipeline: pipeline, skinningByObjectID: skinningByObjectID)
        }
        #endif
        return PuppetAttachmentFrameContext(
            layersByObjectID: layersByID,
            skinningByObjectID: skinningByObjectID,
            sceneSize: sceneSize
        )
    }

    #if DEBUG
    /// Per-objectID dedup so the skinning-gate reason logs once per change, not per frame.
    private var lastLoggedPuppetSkinningReason: [String: String] = [:]

    /// Logs why each puppet's GPU skinning is enabled or gated off (see `logPuppetSkinningReason`).
    private func logResolvedPuppetSkinning(
        pipeline: WPEPreparedRenderPipeline,
        skinningByObjectID: [String: PuppetSkinningState]
    ) {
        for layer in pipeline.layers where layer.puppetModel != nil {
            let objectID = layer.graphLayer.objectID
            let state = skinningByObjectID[objectID]
            let enabled = state?.enabled ?? false
            let reason = state?.reason ?? "no-state"
            let summary = "\(enabled ? "ENABLED" : "DISABLED")/\(reason)"
            guard lastLoggedPuppetSkinningReason[objectID] != summary else { continue }
            lastLoggedPuppetSkinningReason[objectID] = summary
            Logger.info(
                "🦴 [puppet-skin] obj=\(objectID) name=\(layer.graphLayer.objectName) "
                    + "skinning=\(enabled ? "ENABLED" : "DISABLED") reason=\(reason)",
                category: .wpeRender
            )
        }
    }
    #endif

    /// The default-on skinning gate: only enable GPU skinning when the puppet's hierarchy, skin
    /// indices, palette bounds, and attached children are all supported. Otherwise the puppet renders
    /// the static assembled MDLV mesh (the pre-skinning known-good baseline).
    private func validatedSkinningState(
        for layer: WPERenderLayer,
        model: WPEPuppetModel,
        attachedChildNames: Set<String>,
        runtimeUniforms: WPEMetalRuntimeUniforms
    ) -> PuppetSkinningState {
        let attachmentsByName = Dictionary(
            model.attachments.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let boneBindByIndex = Dictionary(
            model.bones.compactMap { bone -> (Int, simd_float4x4)? in
                WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix).map { (bone.index, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        func disabled(_ reason: String) -> PuppetSkinningState {
            PuppetSkinningState(
                enabled: false,
                palette: [],
                attachmentsByName: attachmentsByName,
                boneBindByIndex: boneBindByIndex,
                reason: reason
            )
        }

        guard UserDefaults.standard.object(forKey: "WPEPuppetEnableSkinning") as? Bool ?? true else {
            return disabled("user-disabled")
        }
        let animationLayers = puppetAnimationLayers(for: layer, model: model)
        guard !animationLayers.isEmpty else { return disabled("no-animation") }
        // If a child attaches to an anchor we cannot resolve, refuse to skin this parent so the body
        // never moves out from under a face/hair layer we are unable to follow.
        guard attachedChildNames.allSatisfy({ attachmentsByName[$0] != nil }) else {
            return disabled("unresolved-attachment")
        }
        guard WPEPuppetAnimationEvaluator.hasUsableHierarchy(layers: animationLayers, bones: model.bones) else {
            return disabled("missing-hierarchy")
        }
        let evaluation = WPEPuppetAnimationEvaluator.paletteEvaluation(
            layers: animationLayers,
            bones: model.bones,
            at: runtimeUniforms.time
        )
        guard evaluation.parentChannelMapSucceeded, !evaluation.palette.isEmpty else {
            return disabled("palette-unresolved")
        }
        guard Self.skinBlendIndicesAreInRange(in: model.meshes, paletteCount: evaluation.palette.count) else {
            return disabled("skin-index-out-of-range")
        }
        if let detail = paletteBoundFailureDetail(layers: animationLayers, bones: model.bones, meshes: model.meshes) {
            return disabled("palette-unbounded[\(detail)]")
        }
        return PuppetSkinningState(
            enabled: true,
            palette: evaluation.palette,
            attachmentsByName: attachmentsByName,
            boneBindByIndex: boneBindByIndex,
            reason: evaluation.transformSpace?.rawValue ?? "bind"
        )
    }

    /// Samples the palette across the clip and rejects skinning if any frame is non-finite or moves a
    /// skinned vertex further than a puppet-size-relative bound — the catch for an otherwise "finite"
    /// but exploding palette that frame-0==identity alone would not detect.
    /// Returns nil when every sampled frame's palette is finite and bounded; otherwise a short
    /// failure detail (frame / transform space / vertex-delta vs. allowed) that rides on the
    /// `palette-unbounded` reason so the skinning-gate log shows WHY a puppet was rejected — a near-miss
    /// delta means the threshold is too tight, a huge delta means the palette evaluation is exploding.
    private func paletteBoundFailureDetail(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        meshes: [WPEPuppetMesh]
    ) -> String? {
        guard let base = layers.first(where: { !$0.additive }) ?? layers.first else { return "no-base-layer" }
        let fps = Double(base.animation.fps)
        guard fps.isFinite, fps > 0 else { return "bad-fps" }
        let last = max(base.animation.frameCount, 1)
        let frames = Array(Set([0, 1, last / 4, last / 2, (last * 3) / 4, last])).sorted()
        let extent = Self.modelExtent(meshes: meshes)
        let maxAllowedDelta = max(Float(96), extent * 0.12)
        for frame in frames {
            let time = Double(frame) / fps / max(base.rate, 0.0001)
            let evaluation = WPEPuppetAnimationEvaluator.paletteEvaluation(layers: layers, bones: bones, at: time)
            guard evaluation.parentChannelMapSucceeded,
                  !evaluation.palette.isEmpty,
                  evaluation.palette.allSatisfy(WPEPuppetAnimationEvaluator.matrixIsFinite) else {
                let finite = evaluation.palette.allSatisfy(WPEPuppetAnimationEvaluator.matrixIsFinite)
                return "frame=\(frame) parentMap=\(evaluation.parentChannelMapSucceeded) "
                    + "empty=\(evaluation.palette.isEmpty) finite=\(finite)"
            }
            let delta = Self.maxSkinnedVertexDelta(meshes: meshes, palette: evaluation.palette)
            guard delta <= maxAllowedDelta else {
                return "frame=\(frame) space=\(evaluation.transformSpace?.rawValue ?? "nil") "
                    + "Δ=\(Int(delta))>\(Int(maxAllowedDelta)) extent=\(Int(extent))"
            }
        }
        return nil
    }

    /// Every skin-blend index with positive, finite weight must address a real palette entry. The
    /// shader clamps negatives to bone 0, so a negative index with weight is a malformed mesh we must
    /// reject here rather than skin against the wrong (or out-of-range) bone.
    private static func skinBlendIndicesAreInRange(in meshes: [WPEPuppetMesh], paletteCount: Int) -> Bool {
        guard paletteCount > 0 else { return false }
        for mesh in meshes {
            for vertex in mesh.vertices {
                let weights = vertex.skinBlendWeights
                let indices = vertex.skinBlendIndices
                func valid(_ index: Int32, _ weight: Float) -> Bool {
                    guard weight.isFinite else { return false }
                    guard weight > 0 else { return true }
                    return index >= 0 && Int(index) < paletteCount
                }
                guard valid(indices.x, weights.x), valid(indices.y, weights.y),
                      valid(indices.z, weights.z), valid(indices.w, weights.w) else { return false }
            }
        }
        return true
    }

    private static func modelExtent(meshes: [WPEPuppetMesh]) -> Float {
        var minPoint = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for mesh in meshes {
            for vertex in mesh.vertices {
                let p = SIMD2<Float>(vertex.position.x, vertex.position.y)
                minPoint = min(minPoint, p)
                maxPoint = max(maxPoint, p)
            }
        }
        guard minPoint.x.isFinite, maxPoint.x.isFinite else { return 1 }
        return max(maxPoint.x - minPoint.x, maxPoint.y - minPoint.y, 1)
    }

    private static func maxSkinnedVertexDelta(meshes: [WPEPuppetMesh], palette: [simd_float4x4]) -> Float {
        var maxDelta: Float = 0
        for mesh in meshes {
            for vertex in mesh.vertices {
                let weights = max(vertex.skinBlendWeights, SIMD4<Float>(repeating: 0))
                let weightSum = weights.x + weights.y + weights.z + weights.w
                guard weightSum > 0.00001 else { continue }
                let source = SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 1)
                let indices = vertex.skinBlendIndices
                var skinned = SIMD4<Float>(repeating: 0)
                func add(_ index: Int32, _ weight: Float) {
                    guard weight > 0 else { return }
                    if index >= 0, Int(index) < palette.count {
                        skinned += weight * (palette[Int(index)] * source)
                    } else {
                        skinned += weight * source
                    }
                }
                add(indices.x, weights.x)
                add(indices.y, weights.y)
                add(indices.z, weights.z)
                add(indices.w, weights.w)
                skinned /= weightSum
                let dx = skinned.x - source.x
                let dy = skinned.y - source.y
                maxDelta = max(maxDelta, (dx * dx + dy * dy).squareRoot())
            }
        }
        return maxDelta
    }

    /// Re-derives an attached child's transform from its parent puppet's animated anchor bone. The
    /// child's static (parent-baked) origin already places it correctly at the bind pose, so we add
    /// only the anchor's per-frame scene-space motion; at the bind pose the delta is exactly zero.
    ///
    /// ON-DEVICE VALIDATION POINT: the MDAT bind matrix is treated as a bone-LOCAL anchor offset, so
    /// the model-space anchor is `boneBind · MDAT`. The model→scene mapping (puppetModelPointToScene)
    /// is the convention most worth verifying on-device; both anchor points share it, so any constant
    /// offset cancels and only the parent's scale/rotation shapes the followed motion.
    private func layerApplyingAttachmentFollow(
        _ layer: WPERenderLayer,
        context: PuppetAttachmentFrameContext
    ) -> WPERenderLayer {
        guard let parentID = layer.parentObjectID,
              let attachmentName = layer.attachment,
              let parent = context.layersByObjectID[parentID]?.graphLayer,
              let parentState = context.skinningByObjectID[parentID],
              parentState.enabled,
              let attachment = parentState.attachmentsByName[attachmentName],
              attachment.boneIndex >= 0,
              attachment.boneIndex < parentState.palette.count else {
            return layer
        }
        let boneBind = parentState.boneBindByIndex[attachment.boneIndex] ?? matrix_identity_float4x4
        let anchorBindModel = boneBind * attachment.matrix
        let anchorCurrentModel = parentState.palette[attachment.boneIndex] * anchorBindModel
        let bindPoint = SIMD2<Float>(anchorBindModel.columns.3.x, anchorBindModel.columns.3.y)
        let currentPoint = SIMD2<Float>(anchorCurrentModel.columns.3.x, anchorCurrentModel.columns.3.y)
        let bindScene = puppetModelPointToScene(bindPoint, layer: parent, sceneSize: context.sceneSize)
        let currentScene = puppetModelPointToScene(currentPoint, layer: parent, sceneSize: context.sceneSize)
        let delta = SIMD2<Float>(currentScene.x - bindScene.x, currentScene.y - bindScene.y)
        guard delta.x.isFinite, delta.y.isFinite else { return layer }
        return replacingGeometryOrigin(of: layer, bySceneOffset: delta, sceneSize: context.sceneSize)
    }

    /// A WPE origin component in `0...1` is a normalized fraction of the scene; outside that range it
    /// is already in pixels. Resolve to pixels so an attachment delta (always pixels) can be added.
    private static func scenePixelOrigin(from origin: SIMD3<Double>, sceneSize: CGSize) -> SIMD2<Double> {
        let sceneWidth = max(Double(sceneSize.width), 1)
        let sceneHeight = max(Double(sceneSize.height), 1)
        let x = (origin.x >= 0 && origin.x <= 1) ? origin.x * sceneWidth : origin.x
        let y = (origin.y >= 0 && origin.y <= 1) ? origin.y * sceneHeight : origin.y
        return SIMD2<Double>(x, y)
    }

    private func puppetModelPointToScene(
        _ point: SIMD2<Float>,
        layer: WPERenderLayer,
        sceneSize: CGSize
    ) -> SIMD2<Float> {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        let scaleX = max(abs(Float(geometry.scale.x)), 0.0001)
        let scaleY = max(abs(Float(geometry.scale.y)), 0.0001)
        let width = max(Float(geometry.size?.width ?? 1) * scaleX, 0.0001)
        let height = max(Float(geometry.size?.height ?? 1) * scaleY, 0.0001)
        let originX = Float(geometry.origin.x)
        let originY = Float(geometry.origin.y)
        let originXPixels = (originX >= 0 && originX <= 1) ? originX * sceneWidth : originX
        let originYPixels = (originY >= 0 && originY <= 1) ? originY * sceneHeight : originY
        let anchor = SIMD2<Float>(originXPixels - sceneWidth * 0.5, originYPixels - sceneHeight * 0.5)
        let center = anchor + Self.alignmentCenterOffset(alignment: geometry.alignment, width: width, height: height)
        let local = SIMD2<Float>(
            (point.x - Float(geometry.puppetMeshCenter.x)) * scaleX,
            (point.y - Float(geometry.puppetMeshCenter.y)) * scaleY
        )
        let angle = Float(geometry.angles.z)
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2<Float>(
            center.x + c * local.x - s * local.y,
            center.y + s * local.x + c * local.y
        )
    }

    private func replacingGeometryOrigin(
        of layer: WPERenderLayer,
        bySceneOffset delta: SIMD2<Float>,
        sceneSize: CGSize
    ) -> WPERenderLayer {
        let geometry = layer.geometry
        let originPixels = Self.scenePixelOrigin(from: geometry.origin, sceneSize: sceneSize)
        let adjustedGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(
                originPixels.x + Double(delta.x),
                originPixels.y + Double(delta.y),
                geometry.origin.z
            ),
            scale: geometry.scale,
            angles: geometry.angles,
            alignment: geometry.alignment,
            size: geometry.size,
            puppetMeshCenter: geometry.puppetMeshCenter,
            alpha: geometry.alpha,
            alphaAnimation: geometry.alphaAnimation,
            color: geometry.color,
            brightness: geometry.brightness
        )
        return WPERenderLayer(
            objectID: layer.objectID,
            objectName: layer.objectName,
            visible: layer.visible,
            imagePath: layer.imagePath,
            materialPath: layer.materialPath,
            puppetPath: layer.puppetPath,
            parentObjectID: layer.parentObjectID,
            attachment: layer.attachment,
            animationLayers: layer.animationLayers,
            geometry: adjustedGeometry,
            localGeometry: layer.localGeometry,
            compositeA: layer.compositeA,
            compositeB: layer.compositeB,
            localFBOs: layer.localFBOs,
            passes: layer.passes,
            parallaxDepth: layer.parallaxDepth
        )
    }

    private func encodePuppetMaterialPassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws -> Bool {
        guard case .material = pass.pass.phase,
              case .layerComposite = pass.pass.target,
              let model = puppetModel else {
            return false
        }
        if Self.deferPuppetMeshWarp {
            // Intentional fallthrough: the dispatcher's genericimage2/4 path resolves
            // texture0 with the SAME atlas precedence used below
            // (`textureBindings[0] ?? textures[0] ?? source`). Because this pass targets
            // `.layerComposite`, `usesObjectQuadGeometry` is false, so it renders the
            // atlas at local UV 1:1 via `wpe_fullscreen_vertex` (no mesh warp). The warp
            // is applied later by `encodePuppetSceneCompositePassIfNeeded`.
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard !meshes.isEmpty else { return false }

        let normalizedShader = WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader)
        guard normalizedShader == "genericimage2" || normalizedShader == "genericimage4" else {
            return false
        }

        let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )

        let fragmentName = normalizedShader == "genericimage4"
            ? "wpe_genericimage4_fragment"
            : "wpe_genericimage2_fragment"
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: "wpe_puppet_mesh_vertex",
            fragmentName: fragmentName,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        encoder.setFragmentTexture(primary, index: 0)

        let hasMask: Bool
        if normalizedShader == "genericimage4" {
            let maskRef = pass.textureBindings[1] ?? pass.pass.textures[1]
            if let maskRef {
                let mask = try WPEMetalShaderInputs.resolve(
                    reference: maskRef,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                encoder.setFragmentTexture(mask, index: 1)
                hasMask = true
            } else {
                encoder.setFragmentTexture(primary, index: 1)
                hasMask = false
            }
        } else {
            hasMask = false
        }

        var uniforms = genericImageUniforms(for: pass, layer: layer, hasMask: hasMask)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)

        // Skinning is resolved via `puppetBonePalette` (validated/cached once per frame in
        // `makeAttachmentFrameContext`); the identity-palette fallback reproduces the assembled rest mesh.
        let paletteState = puppetBonePalette(for: skinningState)
        var meshUniforms = WPEPuppetMeshUniforms(
            localSizeAndMode: SIMD4<Float>(
                Float(max(destination.texture.width, 1)),
                Float(max(destination.texture.height, 1)),
                Float(paletteState.bonePalette.count),
                paletteState.skinningEnabled
            ),
            meshCenterAndPadding: SIMD4<Float>(
                Float(layer.geometry.puppetMeshCenter.x),
                Float(layer.geometry.puppetMeshCenter.y),
                0,
                0
            )
        )

        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(
            &meshUniforms,
            length: MemoryLayout<WPEPuppetMeshUniforms>.stride,
            index: 1
        )

        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    /// Deferred-warp final composite (gated by `deferPuppetMeshWarp`): the base + effect chain ran in
    /// puppet atlas/local UV space; here the skinned mesh warps that result into the scene, replacing
    /// the rectangular `copy`-to-`.scene` pass. Placement is copied 1:1 from `objectQuadUniforms` so a
    /// bind-pose, no-effect puppet stays byte-identical to the current path.
    private func encodePuppetSceneCompositePassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws -> Bool {
        guard Self.deferPuppetMeshWarp,
              case .scene = pass.pass.target,
              let model = puppetModel else {
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard !meshes.isEmpty else { return false }
        guard WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) == "copy" else {
            return false
        }

        let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let sourceTexture = try WPEMetalShaderInputs.resolve(
            reference: sourceReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let quadUniforms = objectQuadUniforms(
            for: layer,
            sceneSize: frameState.sceneSize,
            cameraParallax: frameState.cameraParallax,
            sourceTexture: sourceTexture
        )
        let localSize = puppetCompositeLocalSize(for: layer, sourceTexture: sourceTexture)
        let paletteState = puppetBonePalette(for: skinningState)

        // Placement copied from the current final object-quad path:
        //   centerAndSize        -> objectCenterAndSize
        //   sceneSizeAndRotation -> sceneSizeAndRotation
        //   uvSignAndPadding.xy  -> meshCenterAndScaleSign.zw
        // The vertex uses objectCenterAndSize.zw / localSize to produce the same screen-space scale
        // `wpe_object_quad_vertex` applied to the layer FBO.
        var compositeUniforms = WPEPuppetSceneCompositeUniforms(
            localSizeAndMode: SIMD4<Float>(
                localSize.x,
                localSize.y,
                Float(paletteState.bonePalette.count),
                paletteState.skinningEnabled
            ),
            meshCenterAndScaleSign: SIMD4<Float>(
                Float(layer.geometry.puppetMeshCenter.x),
                Float(layer.geometry.puppetMeshCenter.y),
                quadUniforms.uvSignAndPadding.x,
                quadUniforms.uvSignAndPadding.y
            ),
            objectCenterAndSize: quadUniforms.centerAndSize,
            sceneSizeAndRotation: quadUniforms.sceneSizeAndRotation
        )

        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: "wpe_puppet_scene_composite_vertex",
            fragmentName: "wpe_copy_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        encoder.setFragmentTexture(sourceTexture, index: 0)
        // Premultiplied alpha (commit 968cf50) stays intact: the source layer/effect FBO is already
        // premultiplied, `wpe_copy_fragment` returns it unchanged, and `pass.pass.blending` is the
        // graph's existing `premultiplied*` final scene blend.
        var copyUniforms = WPECopyUniforms(uvOffset: SIMD2<Float>(0, 0))
        encoder.setFragmentBytes(&copyUniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(
            &compositeUniforms,
            length: MemoryLayout<WPEPuppetSceneCompositeUniforms>.stride,
            index: 1
        )
        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    private func puppetBonePalette(
        for skinningState: PuppetSkinningState?
    ) -> (bonePalette: [simd_float4x4], skinningEnabled: Float) {
        // When the skinning gate rejects (partial hierarchy, out-of-range indices, unbounded palette,
        // unfollowable attached child) the identity palette reproduces the assembled MDLV rest mesh
        // (no-regression guard). Hidden override: `defaults write Taijia.LiveWallpaper
        // WPEPuppetEnableSkinning -bool NO`.
        let resolvedPalette = skinningState?.enabled == true ? (skinningState?.palette ?? []) : []
        let bonePalette = resolvedPalette.isEmpty
            ? WPEPuppetAnimationEvaluator.identityPalette(count: 1)
            : resolvedPalette
        let skinningEnabled: Float = resolvedPalette.isEmpty ? 0 : 1
        return (bonePalette, skinningEnabled)
    }

    private func puppetCompositeLocalSize(
        for layer: WPERenderLayer,
        sourceTexture: MTLTexture
    ) -> SIMD2<Float> {
        // Match `objectQuadUniforms`: use authored/resolved geometry size for placement, falling back
        // to the source-texture dimensions only when size is absent.
        let width = Float(layer.geometry.size?.width ?? CGFloat(sourceTexture.width))
        let height = Float(layer.geometry.size?.height ?? CGFloat(sourceTexture.height))
        return SIMD2<Float>(max(width, 1), max(height, 1))
    }

    private func bindPuppetBonePalette(
        _ bonePalette: [simd_float4x4],
        encoder: MTLRenderCommandEncoder
    ) throws {
        let bonePaletteBuffer = bonePalette.withUnsafeBytes { rawBuffer in
            device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
        }
        guard let bonePaletteBuffer else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        encoder.setVertexBuffer(bonePaletteBuffer, offset: 0, index: 2)
    }

    private func drawPuppetMeshes(
        _ meshes: [WPEPuppetMesh],
        encoder: MTLRenderCommandEncoder
    ) throws {
        for mesh in meshes {
            let vertices = mesh.vertices.map { vertex in
                WPEMetalPuppetVertex(
                    position: SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 0),
                    uv: SIMD4<Float>(vertex.uv.x, vertex.uv.y, 0, 0),
                    skinBlendIndices: SIMD4<UInt32>(
                        UInt32(max(vertex.skinBlendIndices.x, 0)),
                        UInt32(max(vertex.skinBlendIndices.y, 0)),
                        UInt32(max(vertex.skinBlendIndices.z, 0)),
                        UInt32(max(vertex.skinBlendIndices.w, 0))
                    ),
                    skinBlendWeights: SIMD4<Float>(
                        vertex.skinBlendWeights.x,
                        vertex.skinBlendWeights.y,
                        vertex.skinBlendWeights.z,
                        vertex.skinBlendWeights.w
                    )
                )
            }
            let vertexBuffer = vertices.withUnsafeBytes { rawBuffer in
                device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
            }
            guard let vertexBuffer else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            let indices = mesh.indices
            let indexBuffer = indices.withUnsafeBytes { rawBuffer in
                device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
            }
            guard let indexBuffer else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }

            if mesh.parts.isEmpty {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indices.count,
                    indexType: .uint16,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
            } else {
                for part in mesh.parts where part.count > 0 {
                    let start = max(part.start, 0)
                    let count = min(part.count, max(indices.count - start, 0))
                    guard count > 0 else { continue }
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: count,
                        indexType: .uint16,
                        indexBuffer: indexBuffer,
                        indexBufferOffset: start * MemoryLayout<UInt16>.stride
                    )
                }
            }
        }
    }

    /// Breaks the `_rt_*` scene-alias hazard.
    private func snapshotFullFrameBufferIfAliasingScene(
        pass: WPEPreparedRenderPass,
        destinationTexture: MTLTexture,
        targetID: WPEMetalTargetID,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        guard targetID == .scene else { return }
        let aliases = textureReferences(for: pass).compactMap { reference -> String? in
            guard case .fbo(let name) = reference,
                  WPEMetalShaderInputs.isSceneAliasName(name),
                  frameState.latestNamedTextures[name] == nil else {
                return nil
            }
            return name
        }
        guard let alias = aliases.first else { return }
        let snapshot = try targetPool.texture(
            for: .fbo(name: alias),
            layer: layer,
            sceneSize: frameState.sceneSize,
            avoiding: destinationTexture
        )
        if let source = frameState.currentFrameSceneTexture {
            try copyTexture(source, to: snapshot, commandBuffer: commandBuffer)
            frameState.markInitialized(snapshot)
        } else {
            try clearTexture(snapshot, color: clearColor(for: .scene), commandBuffer: commandBuffer)
            frameState.markInitialized(snapshot)
        }
        frameState.latestNamedTextures[alias] = snapshot
    }

    private func clearTexture(
        _ texture: MTLTexture,
        color: MTLClearColor,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = color
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.endEncoding()
    }

    /// Phase 2C audit fix: blit-copies a prior physical texture into the pool's secondary slot so ping-pong renders that blend or depth-test have a defined source to load.
    private func copyTexture(
        _ source: MTLTexture,
        to destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: destination.width, height: destination.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        blit.endEncoding()
    }

    private func encodeCopy(
        reference: WPETextureReference,
        target: WPERenderTarget,
        layer: WPERenderLayer,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: target)
        let initialPreviousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = reference == .previous
        let destination = try targetTexture(
            for: target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? initialPreviousTextureForTarget : nil
        )

        let previousTextureForTarget: MTLTexture?
        if readsCurrentTarget {
            previousTextureForTarget = try previousTextureForRead(
                targetID: targetID,
                matching: destination.texture,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
        } else {
            previousTextureForTarget = initialPreviousTextureForTarget
        }

        if readsCurrentTarget,
           let previousTextureForTarget,
           ObjectIdentifier(previousTextureForTarget) != ObjectIdentifier(destination.texture),
           !frameState.hasInitialized(destination.texture) {
            try copyTexture(
                previousTextureForTarget,
                to: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(destination.texture)
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = frameState.hasInitialized(destination.texture) ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor(for: destination.id)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)

        encoder.setRenderPipelineState(try renderPipeline(
            fragmentName: "wpe_copy_fragment",
            blendMode: "disabled",
            colorPixelFormat: destination.texture.pixelFormat
        ))
        encoder.setFragmentTexture(
            try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            ),
            index: 0
        )
        // Parallax is a geometry translation applied in object-quad scene
        // passes; raw-pointer UV shifts are intentionally not applied here.
        // (Plain
        // full-frame layers routed through this fullscreen copy don't parallax —
        // see the camera-parallax limitations note.)
        var uniforms = WPECopyUniforms(uvOffset: SIMD2<Float>(0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Thin delegate so call sites — including `WPEMetalShaderDispatcher` across files — keep the same call shape after the pipeline cache became a separate type.
    func renderPipeline(
        vertexName: String = "wpe_fullscreen_vertex",
        fragmentName: String,
        blendMode: String = "disabled",
        colorPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat,
        depthPixelFormat: MTLPixelFormat = .invalid
    ) throws -> MTLRenderPipelineState {
        try pipelineCache.pipelineState(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: blendMode,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
    }

    func usesObjectQuadGeometry(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        cameraParallax: WPECameraParallaxFrame = .neutral
    ) -> Bool {
        guard case .scene = pass.pass.target else { return false }
        if layer.geometry == .identity {
            // Identity full-frame layers normally take the fullscreen copy path.
            // Route them through the object quad (an identical full-scene quad)
            // only when there's an actual parallax shift to apply, leaving the
            // common no-parallax path byte-for-byte unchanged.
            return layer.parallaxDepth != 0 && cameraParallax.smoothed != SIMD2<Float>(0, 0)
        }
        // WPE fullscreen/passthrough utility layers (compose/project/fullscreen)
        // capture + copy the full frame 1:1. Their FINAL scene composite stays
        // fullscreen too, EXCEPT a plain `composelayer.json` authored into a
        // safe sub-rect (an audio-bar visualizer box), whose output is confined
        // to that box via the object quad. Capture/effect passes target the
        // layer composite (not `.scene`), so they were already excluded by the
        // `guard case .scene` above and remain fullscreen.
        if WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath(layer.imagePath) {
            guard Self.subregionComposeOutputEnabled else { return false }
            let decision = WPEMetalSceneCaptureUtilityModels.outputGeometry(
                path: layer.imagePath,
                geometry: layer.geometry,
                sceneSize: currentSceneSize
            )
            let key = "decide:\(layer.objectID)"
            if loggedSubregionDiag.insert(key).inserted {
                Logger.warning(
                    "🟦[ComposeSubregion] decide objID=\(layer.objectID) shader=\(pass.pass.shader) target=\(String(describing: pass.pass.target)) decision=\(decision) sceneSize=\(Int(currentSceneSize.width))x\(Int(currentSceneSize.height)) origin=\(layer.geometry.origin.x),\(layer.geometry.origin.y) size=\(String(describing: layer.geometry.size)) scale=\(layer.geometry.scale.x)",
                    category: .wpeRender
                )
            }
            return decision == .subregion
        }
        return true
    }

    func objectQuadUniforms(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame = .neutral,
        sourceTexture: MTLTexture
    ) -> WPEObjectQuadUniforms {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        // Identity (full-frame) layers map to a scene-sized quad centered at the
        // origin — identical coverage + UV to `wpe_fullscreen_vertex` — plus the
        // camera-parallax shift. (Only reached when parallax is active; see
        // `usesObjectQuadGeometry`.)
        if geometry == .identity {
            let parallax = cameraParallax.pixelOffset(depth: layer.parallaxDepth, sceneSize: sceneSize)
            return WPEObjectQuadUniforms(
                centerAndSize: SIMD4<Float>(parallax.x, parallax.y, sceneWidth, sceneHeight),
                sceneSizeAndRotation: SIMD4<Float>(sceneWidth, sceneHeight, 0, 0),
                uvSignAndPadding: SIMD4<Float>(1, 1, 0, 0)
            )
        }
        // Scene-capture utility subregion layers use the SAME object-quad geometry
        // as the normal placed-layer path below. At render time `geometry.origin`
        // is already in the renderer's top-left pixel convention (resolved by the
        // parser/builder), so the `originX - sceneWidth*0.5` anchor places the box
        // correctly. An earlier center-origin special-case here pushed the box
        // off-screen (runtime origin (1089,1862) → NDC (0.57,1.72)) and blanked
        // the bars; the raw scene.json center-origin value never reaches here.
        let baseWidth = Float(geometry.size?.width ?? CGFloat(sourceTexture.width))
        let baseHeight = Float(geometry.size?.height ?? CGFloat(sourceTexture.height))
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let width = max(baseWidth * max(abs(scaleX), 0.0001), 0.0001)
        let height = max(baseHeight * max(abs(scaleY), 0.0001), 0.0001)
        let originX = Float(geometry.origin.x)
        let originY = Float(geometry.origin.y)
        let originXPixels = (originX >= 0 && originX <= 1) ? originX * sceneWidth : originX
        let originYPixels = (originY >= 0 && originY <= 1) ? originY * sceneHeight : originY
        let anchor = SIMD2<Float>(
            originXPixels - sceneWidth * 0.5,
            originYPixels - sceneHeight * 0.5
        )
        let center = anchor + Self.alignmentCenterOffset(
            alignment: geometry.alignment,
            width: width,
            height: height
        ) + cameraParallax.pixelOffset(depth: layer.parallaxDepth, sceneSize: sceneSize)
        if WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath(layer.imagePath),
           loggedSubregionDiag.insert("quad:\(layer.objectID)").inserted {
            Logger.warning(
                "🟩[ComposeSubregion] quad objID=\(layer.objectID) center=(\(Int(center.x)),\(Int(center.y))) size=(\(Int(width)),\(Int(height))) sceneSize=(\(Int(sceneWidth)),\(Int(sceneHeight))) centerNDC=(\(String(format: "%.2f", center.x / max(sceneWidth * 0.5, 1))),\(String(format: "%.2f", center.y / max(sceneHeight * 0.5, 1)))) srcTex=\(sourceTexture.width)x\(sourceTexture.height)",
                category: .wpeRender
            )
        }
        return WPEObjectQuadUniforms(
            centerAndSize: SIMD4<Float>(center.x, center.y, width, height),
            sceneSizeAndRotation: SIMD4<Float>(
                sceneWidth,
                sceneHeight,
                Float(geometry.angles.z),
                0
            ),
            uvSignAndPadding: SIMD4<Float>(
                scaleX < 0 ? -1 : 1,
                scaleY < 0 ? -1 : 1,
                0,
                0
            )
        )
    }

    private static func alignmentCenterOffset(
        alignment: WPESceneAlignment,
        width: Float,
        height: Float
    ) -> SIMD2<Float> {
        switch alignment {
        case .center:
            return SIMD2<Float>(0, 0)
        case .topLeft:
            return SIMD2<Float>(width * 0.5, -height * 0.5)
        case .topRight:
            return SIMD2<Float>(-width * 0.5, -height * 0.5)
        case .bottomLeft:
            return SIMD2<Float>(width * 0.5, height * 0.5)
        case .bottomRight:
            return SIMD2<Float>(-width * 0.5, height * 0.5)
        case .top:
            return SIMD2<Float>(0, -height * 0.5)
        case .bottom:
            return SIMD2<Float>(0, height * 0.5)
        case .left:
            return SIMD2<Float>(width * 0.5, 0)
        case .right:
            return SIMD2<Float>(-width * 0.5, 0)
        }
    }

    #if DEBUG
    /// Blit a copy of the current scene output into a fresh texture and stash it
    /// for `WPEDumpScenePasses` PNG dumping. The blit is encoded inline so it
    /// captures the output exactly as of this pass in the command stream.
    private func captureScenePassIfDumping(
        _ enabled: Bool,
        label: String,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard enabled,
              let snapshot = try? makeOutputTexture(size: CGSize(width: output.width, height: output.height)),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(
            from: output,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
            to: snapshot,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        scenePassDumps.append((label: label, texture: snapshot))
    }
    #endif

    #if DEBUG
    /// Decode any sampleable texture (incl. BC/DXT, RG88, R8) into rgba8 by
    /// sampling it through a fullscreen copy, so the PNG dumper can visualize
    /// compressed character/scene textures that the raw byte dumper skips.
    func debugDecodeToRGBA(_ source: MTLTexture) -> MTLTexture? {
        guard let output = try? makeOutputTexture(size: CGSize(width: source.width, height: source.height)),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let pipeline = try? renderPipeline(
                  vertexName: "wpe_fullscreen_vertex",
                  fragmentName: "wpe_util_copy_fragment",
                  blendMode: "disabled",
                  colorPixelFormat: output.pixelFormat
              ) else {
            return nil
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }
    #endif

    private func makeOutputTexture(size: CGSize) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.outputPixelFormat,
            width: max(Int(size.width), 1),
            height: max(Int(size.height), 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor output"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        return texture
    }

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

    private func previousTextureForRead(
        targetID: WPEMetalTargetID,
        matching destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws -> MTLTexture {
        if let texture = frameState.latestTexture(for: targetID) {
            return texture
        }
        let texture = try makeClearedPreviousTexture(
            matching: destination,
            targetID: targetID,
            commandBuffer: commandBuffer
        )
        frameState.seedPreviousTexture(texture, targetID: targetID)
        frameState.markInitialized(texture)
        return texture
    }

    private func makeClearedPreviousTexture(
        matching texture: MTLTexture,
        targetID: WPEMetalTargetID,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let cleared = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        cleared.label = "WPE Metal bootstrap previous"
        WPEMetalTextureMetadataRegistry.shared.register(texture: cleared)

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = cleared
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = clearColor(for: targetID)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.endEncoding()
        return cleared
    }

    /// Phase 2D-E: shared dispatch path for single-input effect built-ins (opacity, scroll, pulse, iris, waterwaves).
    func dispatchSingleSampleEffect<U: BitwiseCopyable>(
        fragmentName: String,
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat,
        uniforms: U
    ) throws {
        let usesObjectQuad = usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: fragmentName,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let texture = try WPEMetalShaderInputs.resolve(
            reference: reference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        encoder.setFragmentTexture(texture, index: 0)
        var local = uniforms
        encoder.setFragmentBytes(&local, length: MemoryLayout<U>.stride, index: 0)
        if usesObjectQuad {
            var quadUniforms = objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: texture
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// WPE's waterwaves effect: a masked, time-driven UV displacement. The opacity mask in
    /// texture slot 1 localizes the wave (so it ripples a character's hair, not the whole image).
    func dispatchWaterWavesEffect(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat,
        time: Float,
        speed: Float,
        scale: Float,
        strength: Float,
        exponent: Float,
        direction: SIMD2<Float>,
        debugMode: Float
    ) throws {
        let usesObjectQuad = usesObjectQuadGeometry(for: pass, layer: layer)
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_effect_waterwaves_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let sourceTexture = try WPEMetalShaderInputs.resolve(
            reference: sourceReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let maskReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? pass.pass.binds[1]
        let maskTexture: MTLTexture
        let hasMask: Float
        if let maskReference {
            maskTexture = try WPEMetalShaderInputs.resolve(
                reference: maskReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            hasMask = 1
        } else {
            maskTexture = sourceTexture
            hasMask = 0
        }
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(maskTexture, index: 1)

        if !loggedWaterWavesDispatch {
            loggedWaterWavesDispatch = true
            Logger.warning(
                "WPE waterwaves dispatch ran (builtin effect_waterwaves): debugMode=\(debugMode) hasMask=\(hasMask) mask=\(maskTexture.width)x\(maskTexture.height) dest=\(destination.texture.width)x\(destination.texture.height) speed=\(speed) scale=\(scale) strength=\(strength)",
                category: .wpeRender
            )
        }

        WPESceneDebugArtifacts.shared.setWaterWavesPath("Builtin")
        let maskResolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: maskTexture)
        var uniforms = WPEWaterWavesUniforms(
            time: time,
            speed: speed,
            scale: scale,
            strength: strength,
            exponent: exponent,
            directionX: direction.x,
            directionY: direction.y,
            hasMask: hasMask,
            debugMode: debugMode,
            texture1Resolution: SIMD4<Float>(
                Float(maskResolution.textureWidth),
                Float(maskResolution.textureHeight),
                Float(maskResolution.imageWidth),
                Float(maskResolution.imageHeight)
            )
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEWaterWavesUniforms>.stride, index: 0)

        if usesObjectQuad {
            var quadUniforms = objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                sourceTexture: sourceTexture
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// WPE's opacity effect optionally carries an opacity mask in texture slot 1.
    func dispatchOpacityEffect(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_effect_opacity_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let sourceTexture = try WPEMetalShaderInputs.resolve(
            reference: sourceReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let maskReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? pass.pass.binds[1]
        let maskTexture: MTLTexture
        let hasMask: Float
        if let maskReference {
            maskTexture = try WPEMetalShaderInputs.resolve(
                reference: maskReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            hasMask = 1
        } else {
            maskTexture = sourceTexture
            hasMask = 0
        }

        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(maskTexture, index: 1)
        var uniforms = WPEOpacityUniforms(
            opacity: WPEMetalShaderInputs.floatScalar(
                named: ["u_Opacity", "opacity", "amount", "alpha", "g_UserAlpha"],
                in: pass,
                default: 1
            ),
            hasMask: hasMask,
            maskScaleX: Float(destination.texture.width) / Float(max(maskTexture.width, 1)),
            maskScaleY: Float(destination.texture.height) / Float(max(maskTexture.height, 1))
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEOpacityUniforms>.stride, index: 0)

        if usesObjectQuad {
            var quadUniforms = objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: sourceTexture
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// Phase 2D-D: pack scene uniforms for the genericimage* built-ins.
    private static let imageUniformDebugEnabled = UserDefaults.standard.bool(forKey: "WPEAudioDebugLog")
    nonisolated(unsafe) private static var loggedImageUniformNames = Set<String>()

    func genericImageUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasMask: Bool
    ) -> WPEGenericImageUniforms {
        let color = WPEMetalShaderInputs.colorVector(for: pass)
        let gAlpha = WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1)
        let gBrightness = WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1)
        let alpha = gAlpha * Float(layer.geometry.alpha)
        let brightness = gBrightness * Float(layer.geometry.brightness)
        // Diagnostic for the "black silhouette" bug: genericimage shaders do
        // `rgb = sampled.rgb * color.rgb * brightness`, so brightness==0 OR
        // color==0 blacks out the layer while alpha (a separate term) survives.
        // One line per object so the log isn't spammed.
        if Self.imageUniformDebugEnabled,
           Self.loggedImageUniformNames.insert(layer.objectName).inserted {
            Logger.notice(
                "[ImgUniform] \(layer.objectName) shader=\(pass.pass.shader) g_Brightness=\(gBrightness) layerBright=\(layer.geometry.brightness) → brightness=\(brightness) color=(\(color.x),\(color.y),\(color.z)) alpha=\(alpha)",
                category: .wpeRender
            )
        }
        return WPEGenericImageUniforms(
            color: color,
            alphaMaskUV: SIMD4<Float>(alpha, brightness, hasMask ? 1 : 0, 0)
        )
    }

    /// Phase 2D-D: per-particle uniform pack.
    func genericParticleUniforms(for pass: WPEPreparedRenderPass) -> WPEGenericParticleUniforms {
        WPEGenericParticleUniforms(
            color: WPEMetalShaderInputs.colorVector(for: pass),
            sizeAndAge: SIMD4<Float>(
                WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1),
                WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1),
                0,
                0
            )
        )
    }

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

    /// Build (or fetch from cache) an `MTLRenderPipelineState` for a translated shader's fragment function.
    func translatedPipelineState(
        for result: WPEShaderCompileResult,
        vertexName: String? = nil,
        blendMode: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let resolvedVertexName = vertexName ?? result.vertexFunctionName
        let key = TranslatedPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            vertexName: resolvedVertexName,
            fragmentName: result.fragmentFunctionName,
            blendMode: blendMode.lowercased(),
            colorPixelFormat: colorPixelFormat.rawValue,
            depthPixelFormat: depthPixelFormat.rawValue
        )
        if let cached = translatedPipelineCache[key] {
            return cached
        }
        guard let vertex = result.library.makeFunction(name: resolvedVertexName)
            ?? device.makeDefaultLibrary()?.makeFunction(name: resolvedVertexName),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        colorAttachment.pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        Self.applyBlendMode(blendMode.lowercased(), to: colorAttachment)
        let state: MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw WPEMetalRenderExecutorError.pipelineStateBuildFailed(
                name: result.fragmentFunctionName,
                detail: error.localizedDescription
            )
        }
        translatedPipelineCache[key] = state
        return state
    }

    /// Phase 2D-H: pack a runtime uniform buffer matching the layout the transpiler emitted (every uniform takes 1-4 float4 slots).
    func packTranslatedUniforms(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot],
        texturesBySlot: [Int: MTLTexture] = [:],
        destinationTexture: MTLTexture? = nil
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: WPEShaderTranspiler.uniformSlotMaximum)
        for u in layout {
            let value = Self.textureResolutionValue(
                named: u.name,
                texturesBySlot: texturesBySlot,
                destinationTexture: destinationTexture
            ) ?? Self.translatedUniformValue(for: u, in: pass)
            if let length = u.arrayLength {
                Self.packArrayUniform(value, glslType: u.glslType, length: length, slot: u.slot, into: &slots)
                continue
            }
            switch u.glslType {
            case "float", "int", "bool":
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            case "vec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
            case "mat2":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
                slots[u.slot + 1] = SIMD4<Float>(v[2], v[3], 0, 0)
            case "mat3":
                let v = Self.vectorValue(value, count: 9)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
                slots[u.slot + 1] = SIMD4<Float>(v[3], v[4], v[5], 0)
                slots[u.slot + 2] = SIMD4<Float>(v[6], v[7], v[8], 0)
            case "mat4":
                let v = Self.vectorValue(value, count: 16)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
                slots[u.slot + 1] = SIMD4<Float>(v[4], v[5], v[6], v[7])
                slots[u.slot + 2] = SIMD4<Float>(v[8], v[9], v[10], v[11])
                slots[u.slot + 3] = SIMD4<Float>(v[12], v[13], v[14], v[15])
            default:
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            }
        }
        return slots
    }

    private static func translatedUniformValue(
        for uniform: WPEUniformSlot,
        in pass: WPEPreparedRenderPass
    ) -> WPESceneShaderConstantValue? {
        let candidates = translatedUniformNameCandidates(for: uniform)
        if let value = firstValue(in: pass.uniformValues, matching: candidates) {
            return value
        }
        if let value = firstValue(in: pass.pass.constants, matching: candidates) {
            return value
        }
        return uniform.defaultValue
    }

    private static func translatedUniformNameCandidates(for uniform: WPEUniformSlot) -> [String] {
        var candidates: [String] = [uniform.name]
        if let materialName = uniform.materialName, !materialName.isEmpty {
            candidates.append(materialName)
        }
        if uniform.name.hasPrefix("u_") {
            let base = String(uniform.name.dropFirst(2))
            if !base.isEmpty {
                candidates.append(base)
                candidates.append(base.prefix(1).uppercased() + String(base.dropFirst()))
            }
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate).inserted
        }
    }

    private static func firstValue(
        in values: [String: WPESceneShaderConstantValue],
        matching candidates: [String]
    ) -> WPESceneShaderConstantValue? {
        for candidate in candidates {
            if let value = values[candidate] {
                return value
            }
        }
        for candidate in candidates {
            let normalized = candidate.lowercased()
            if let match = values.first(where: { $0.key.lowercased() == normalized }) {
                return match.value
            }
        }
        return nil
    }

    private static func textureResolutionValue(
        named name: String,
        texturesBySlot: [Int: MTLTexture],
        destinationTexture: MTLTexture?
    ) -> WPESceneShaderConstantValue? {
        guard let slot = textureResolutionSlotIndex(for: name),
              let texture = texturesBySlot[slot] else {
            return nil
        }
        return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).shaderValue
    }

    private static func textureResolutionSlotIndex(for name: String) -> Int? {
        let prefix = "g_Texture"
        let suffix = "Resolution"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let slotText = name.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(slotText)
    }

    private static func scalarValue(_ value: WPESceneShaderConstantValue?, default fallback: Float) -> Float {
        switch value {
        case .number(let n): return Float(n)
        case .vector(let v): return Float(v.first ?? Double(fallback))
        case .bool(let b):   return b ? 1 : 0
        case .animated(let v): return Float(v.scalar(at: 0) ?? Double(fallback))
        case .string(let s): return Float(s) ?? fallback
        case nil:            return fallback
        }
    }

    /// Packs a GLSL array uniform (`elemType name[length]`) into `length`
    /// consecutive `float4` slots — one array element per slot, the element's
    /// components in `.x`/`.xy`/`.xyz`/`.xyzw`. This mirrors the transpiler's
    /// per-element read `u.vals[slot + i].<swizzle>` (see
    /// `WPEShaderTranspiler.renderMSL`). Both pack overloads route here so the
    /// scalar/vec packing can never drift apart again — the previous divergence
    /// (`values:` overload packed every array as `vec4[N]`; the per-pass
    /// overload under-read `vec2/3/4[N]` with `count: length`) silently
    /// corrupted scalar `float[N]` uniforms such as `g_AudioSpectrum*[N]`.
    private static func packArrayUniform(
        _ value: WPESceneShaderConstantValue?,
        glslType: String,
        length: Int,
        slot: Int,
        into slots: inout [SIMD4<Float>]
    ) {
        let components: Int
        switch glslType {
        case "vec2": components = 2
        case "vec3": components = 3
        case "vec4": components = 4
        default: components = 1 // float / int / bool — scalar element, read via `.x`
        }
        let flat = vectorValue(value, count: length * components)
        for i in 0..<length {
            let slotIndex = slot + i
            guard slotIndex < slots.count else { break }
            let base = i * components
            slots[slotIndex] = SIMD4<Float>(
                base < flat.count ? flat[base] : 0,
                components > 1 && base + 1 < flat.count ? flat[base + 1] : 0,
                components > 2 && base + 2 < flat.count ? flat[base + 2] : 0,
                components > 3 && base + 3 < flat.count ? flat[base + 3] : 0
            )
        }
    }

    private static func vectorValue(_ value: WPESceneShaderConstantValue?, count: Int) -> [Float] {
        switch value {
        case .vector(let v):
            var out = v.map(Float.init)
            while out.count < count { out.append(0) }
            return out
        case .animated(let v):
            var out = (v.vector(at: 0) ?? []).map(Float.init)
            while out.count < count { out.append(0) }
            return out
        case .number(let n):
            var out = [Float](repeating: 0, count: count)
            out[0] = Float(n)
            return out
        default:
            return [Float](repeating: 0, count: count)
        }
    }

    /// Mirrors WPEMetalPipelineCache.applyBlendMode so the translated pipeline path uses the same blend arithmetic as built-ins.
    private static func applyBlendMode(_ mode: String, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        switch mode {
        case "disabled", "premultiplieddisabled":
            attachment.isBlendingEnabled = false
        case "premultiplied", "premultipliednormal", "premultipliedtranslucent", "premultipliednormalmapped":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case "premultipliedadditive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        case "additive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        case "premultipliedmultiply":
            fallthrough
        case "multiply":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        case "translucent":
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

    /// Texture slots whose bound source is a WPE render target (an FBO/layer
    /// composite or the previous-frame buffer). Those targets already store
    /// premultiplied RGB, so a transpiled straight-alpha shader must
    /// un-premultiply them before running its original math.
    private static func premultipliedInputSlots(for pass: WPEPreparedRenderPass) -> Set<Int> {
        var slots = Set<Int>()
        for slot in 0..<WPEShaderTranspiler.customTextureSlotCount {
            let reference = pass.textureBindings[slot]
                ?? pass.pass.binds[slot]
                ?? pass.pass.textures[slot]
                ?? (slot == 0 ? pass.pass.source : nil)
            if let reference, isPremultipliedRenderTarget(reference) {
                slots.insert(slot)
            }
        }
        return slots
    }

    private static func isPremultipliedRenderTarget(_ reference: WPETextureReference) -> Bool {
        switch reference {
        case .fbo, .previous:
            return true
        case .image, .asset:
            return false
        }
    }

    /// True when the pass targets the premultiplied render-target path, so a
    /// transpiled straight-alpha shader must premultiply its final output.
    private static func usesPremultipliedOutput(blendMode: String) -> Bool {
        blendMode
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .hasPrefix("premultiplied")
    }

    /// Run the WPE preprocessor + the configured `WPEShaderCompiling` over the given prepared pass.
    func compileCustomShader(
        for pass: WPEPreparedRenderPass
    ) throws -> WPEShaderCompileResult {
        guard let program = pass.shader else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }
        let processor = WPEShaderPreprocessor { _, _ in
            nil
        }
        let premultipliedInputSlots = Self.premultipliedInputSlots(for: pass)
        let premultipliedOutput = Self.usesPremultipliedOutput(blendMode: pass.pass.blending)
        let request: WPEShaderCompileRequest
        do {
            request = try processor.process(
                shaderName: program.name,
                vertexSource: program.vertexSource,
                fragmentSource: program.fragmentSource,
                comboValues: pass.comboValues,
                materialTextureBindings: Dictionary(
                    uniqueKeysWithValues: pass.textureBindings.compactMap { (slot, ref) -> (Int, String)? in
                        switch ref {
                        case .image(let p), .asset(let p): return (slot, p)
                        case .fbo(let n): return (slot, n)
                        case .previous: return nil
                        }
                    }
                )
            ).replacingPremultipliedAlphaSettings(
                inputSlots: premultipliedInputSlots,
                output: premultipliedOutput
            )
        } catch let error as WPEShaderCompilerError {
            WPESceneDebugArtifacts.shared.recordShaderFailure(
                shaderName: program.name,
                originalVertex: program.vertexSource,
                processedVertex: nil,
                originalFragment: program.fragmentSource,
                processedFragment: nil,
                translatedMSL: nil,
                errorText: "preprocess failed: \(String(describing: error))"
            )
            throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                name: program.name,
                reason: String(describing: error)
            )
        }
        if let cached = translatedShaderCache[request.translationCacheKey] {
            return cached
        }
        do {
            let result = try shaderCompiler.compile(request)
            translatedShaderCache[request.translationCacheKey] = result
            return result
        } catch let error as WPEShaderCompilerError {
            switch error {
            case .glslPreprocessFailed(let reason),
                 .translationFailed(let reason),
                 .mslLibraryFailed(let reason):
                // The compiler already dumped processed sources; tack on the
                // pre-preprocess originals so a maintainer can diff to see
                // exactly which fixup turned the source unparseable.
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: program.name,
                    originalVertex: program.vertexSource,
                    processedVertex: request.processedVertexSource,
                    originalFragment: program.fragmentSource,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: nil,
                    errorText: "compile failed: \(reason)"
                )
                throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                    name: program.name,
                    reason: reason
                )
            }
        }
    }
}
#endif
