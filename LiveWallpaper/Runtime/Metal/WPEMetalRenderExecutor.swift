#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

final class WPEMetalRenderExecutor {
    /// Builtin shader identities compared across the material/model helpers. `copy`,
    /// `genericImage2`, `genericImage4` match against `normalizedBuiltinShaderName`;
    /// `godraysCombine` is the raw (lowercased) shader path used for source-aliasing.
    enum BuiltinShaderName {
        static let copy = "copy"
        static let genericImage2 = "genericimage2"
        static let genericImage4 = "genericimage4"
        static let godraysCombine = "effects/godrays_combine"
    }

    /// Phase 2A H3: every offscreen target and the on-screen swapchain share
    /// a single sRGB pixel format so render pipelines built for the offscreen
    /// pass can be reused by `present()` without re-creation, and so the
    /// rendered gamma stays stable across offscreen and onscreen passes.
    static let outputPixelFormat: MTLPixelFormat = .rgba8Unorm_srgb
    /// Per-scene output format: `.rgba16Float` for HDR scenes so >1 emissive
    /// survives to the bloom prefilter (an 8-bit target clamps at scene write,
    /// which killed the sun glow); SDR scenes keep the 8-bit sRGB target.
    /// `WPEMetalTextureSnapshotter` clamp+sRGB-encodes rgba16Float, so HDR
    /// scenes get posters/first-frame.png too (fixed 2026-07-06).
    var currentOutputPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat

    /// Optional developer override for the per-puppet deferred-warp decision (see
    /// `shouldDeferPuppetMeshWarp`). `nil` (the default, and always in Release) means "decide
    /// automatically per puppet"; an explicit DEBUG `defaults write Taijia.LiveWallpaper
    /// WPEPuppetDeferMeshWarp -bool YES|NO` forces the warp deferred/direct for every non-clip puppet
    /// (A/B testing). Clip-composite puppets ignore this and never defer.
    static var deferPuppetMeshWarpOverride: Bool? {
        #if DEBUG
        return puppetDefaultsFlagOptional("WPEPuppetDeferMeshWarp")
        #else
        return nil
        #endif
    }

    /// WPE genericimage4 puppet clip-composite (clip-mask RT + CLIPPINGTARGET) so an eye
    /// puppet's pupil is occluded when the blink closes. Default ON; opt out with
    /// `defaults write Taijia.LiveWallpaper WPEPuppetClipComposite -bool NO`.
    /// Still only takes effect when the builder injected a clip-mask binding (texture slot 8).
    static let puppetClipCompositeEnabled: Bool = puppetDefaultsFlagOptional("WPEPuppetClipComposite") ?? true

    /// Reads a puppet bool override from the app's `Taijia.LiveWallpaper` suite first, falling back to
    /// the process `.standard` domain while preserving "unset" (`nil`). Puppet flags MUST share this
    /// so `defaults write Taijia.LiveWallpaper …` is honoured uniformly even when the renderer runs in
    /// a process whose standard domain isn't the app's.
    static func puppetDefaultsFlagOptional(
        _ key: String,
        suite: UserDefaults = .appSuite,
        standard: UserDefaults = .standard
    ) -> Bool? {
        if suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        if standard.object(forKey: key) != nil {
            return standard.bool(forKey: key)
        }
        return nil
    }

    static let staticLayerCacheDefaultsKey = "WPEMetalStaticLayerCacheEnabled"
    static let staticLayerCacheBudgetMiBDefaultsKey = "WPEMetalStaticLayerCacheBudgetMiB"

    /// Opt-in exact composite cache for static WPE layers. Default OFF so the
    /// existing render path stays byte-identical unless explicitly enabled
    /// (`defaults write … WPEMetalStaticLayerCacheEnabled -bool YES`).
    /// Read once on first use, then cached — restart to apply. `readStaticLayerCacheEnabled()`
    /// exposes the live read for tests.
    static let isStaticLayerCacheEnabled: Bool = readStaticLayerCacheEnabled()
    static func readStaticLayerCacheEnabled() -> Bool {
        UserDefaults.standard.object(forKey: staticLayerCacheDefaultsKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: staticLayerCacheDefaultsKey)
    }

    /// VRAM budget for cached composites (MiB; default 256). Over budget → LRU
    /// eviction, and the evicted layer falls back to re-rendering (slower, never wrong).
    /// Read once on first use, then cached — restart to apply.
    static let staticLayerCacheBudgetBytes: Int = {
        let raw = UserDefaults.standard.object(forKey: staticLayerCacheBudgetMiBDefaultsKey)
        let mib = (raw as? NSNumber)?.intValue ?? 256
        return max(0, mib) * 1_048_576
    }()

    /// Mirrors the slot-0 precedence used by
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let targetPool: WPEMetalRenderTargetPool
    let depthCache: WPEMetalDepthStateCache
    private let pipelineCache: WPEMetalPipelineCache
    /// Translates non-built-in shaders via the shipping Swift transpiler.
    let shaderCompiler: WPESwiftShaderCompiler
    /// Phase 2D-H: memoize the per-shader compile across frames so we
    /// don't re-translate every draw call.
    var translatedShaderCache: [String: WPEShaderCompileResult] = [:]

    /// Per-pass fast path keyed by `WPEPreparedRenderPass.id`. `translatedShaderCache`
    /// is keyed by a hash of the *preprocessed* source, so reaching it requires
    /// running the (expensive) GLSL preprocessor every frame just to compute the
    /// key — which dominated the main thread in profiling (custom-shader passes
    /// re-preprocessed every frame). The prepared pipeline is built once at load
    /// and reused per frame, so a pass's result is invariant; caching by pass id
    /// skips the preprocess entirely on the hot path. Pass ids can recur across
    /// scenes, so this is cleared on reload (via `releaseTransientResources`).
    var compiledShaderResultByPassID: [String: WPEShaderCompileResult] = [:]

    /// Sampler states for transpiled shaders' per-slot `wpeSampler<slot>` bindings,
    /// keyed by (clampUVs, noInterpolation). Only four combinations exist, so this
    /// stays tiny; created lazily on first use.
    private var customSamplerStateCache: [Int: MTLSamplerState] = [:]

    /// The `MTLSamplerState` for a custom-shader texture slot, driven by the bound
    /// texture's TEXI flags (registered at load in `WPEMetalTextureMetadataRegistry`).
    /// Unregistered textures (render targets / framebuffers) and unbound slots fall
    /// back to clamp-to-edge + linear — the safe default that never wraps.
    func customShaderSamplerState(for texture: MTLTexture?) -> MTLSamplerState {
        let resolution = texture.map { WPEMetalTextureMetadataRegistry.shared.resolution(for: $0) }
        let clamp = resolution?.clampUVs ?? true
        let nearest = resolution?.noInterpolation ?? false
        let key = (clamp ? 1 : 0) | (nearest ? 2 : 0)
        if let cached = customSamplerStateCache[key] { return cached }
        let descriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = nearest ? .nearest : .linear
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        if WPEMetalTextureLoader.isMipChainEnabled {
            // Default `.notMipmapped` samples level 0 only, matching today's
            // level-0-only upload; opt in to trilinear filtering across the
            // chain the loader now uploads under the same flag.
            descriptor.mipFilter = .linear
        }
        let address: MTLSamplerAddressMode = clamp ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        // Force-unwrap matches the executor's other GPU-object creation: a valid
        // descriptor never fails to produce a sampler state on a live device.
        let state = device.makeSamplerState(descriptor: descriptor)!
        customSamplerStateCache[key] = state
        return state
    }

    /// Merge pre-warmed transpile results into the shader cache. Called on the
    /// main actor AFTER the warm task group drains and BEFORE the first
    /// `render()`, so it never races the lazy compile path (which also runs on
    /// the main actor during render). Idempotent: same source-hash key ⇒ same
    /// deterministic result, so an existing entry is left untouched.
    func seedTranslatedShaderCache(_ entries: [(key: String, result: WPEShaderCompileResult)]) {
        for entry in entries where translatedShaderCache[entry.key] == nil {
            translatedShaderCache[entry.key] = entry.result
        }
    }
    /// Phase 2D-H: cache MTLRenderPipelineState built from translated
    /// shaders. Library + blend + format set is the key.
    private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]
    var previousFrameHistory: PreviousFrameHistory?
    /// Clip-composite role detection depends on the object's animation layers, so cache the resolved
    /// (source→target) part pairs per `objectID` (empty array = clip puppet with no eligible pair).
    var puppetClipPairsCache: [String: [PuppetClipPair]] = [:]
    /// Throttles the one-shot clip-activation diagnostic to once per objectID.
    var loggedClipActivation: Set<String> = []
    var msdfTextPipelineCache: [MSDFTextPipelineKey: MTLRenderPipelineState] = [:]
    var msdfNeutralWhiteTexture: MTLTexture?
    lazy var staticLayerCompositeCache = WPEMetalStaticLayerCompositeCache(
        budgetBytes: WPEMetalRenderExecutor.staticLayerCacheBudgetBytes
    )
    var staticLayerCacheSceneSize: CGSize?
    var loggedStaticLayerCacheHits: Set<String> = []
    /// Throttles the generic4 component-map resolve-failure diagnostic to once per objectID.
    var loggedComponentMapResolveFailures: Set<String> = []

    /// Scene-output ring: per-frame outputs are recycled instead of freshly
    /// allocated every `render()` (~32 MB alloc/free per frame at 4K). A slot
    /// is reused only when (a) no async present of it is still in flight and
    /// (b) it is not among the most recently vended outputs (`maxFramesInFlight`,
    /// min 2) — the renderer re-presents the latest output for static scenes,
    /// `previousFrameHistory` may still read the prior one, and under async
    /// submission an in-flight render may still be writing it.
    var outputTexturePool: [MTLTexture] = []
    /// The most recently vended output textures (newest last); retained count is
    /// `max(2, maxFramesInFlight)` — see `noteVendedOutputTexture`.
    var recentOutputTextureIDs: [ObjectIdentifier] = []
    let presentTracker = PresentInFlightTracker()
    let gpuErrorSink = WPEGPUErrorSink()
    let shaderErrorSink = WPEShaderErrorSink()
    /// Max frames whose command buffers may be in flight at once when submitting
    /// asynchronously. MUST equal the `recentOutputTextureIDs` retention: a vended
    /// output target stays out of the reuse set for exactly that many subsequent
    /// vends, and the semaphore guarantees its render has completed by the time it
    /// falls out — so a target is never recycled while its GPU write is in flight.
    /// (See `isOutputTextureReusable` / `noteVendedOutputTexture`.)
    static let maxFramesInFlight = 2
    /// Backpressure for asynchronous frame submission: gates the render caller
    /// once `maxFramesInFlight` frames are queued so the CPU cannot outrun the GPU
    /// (which would starve the output ring and grow latency unboundedly).
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)

    /// When true, `render()` and the text passes block on GPU completion
    /// (`waitUntilCompleted`) so a CPU read-back of the frame (scene-debug
    /// first-frame snapshot, visual-stats, GPU capture, test pixel diffs) observes
    /// finished pixels. When false — the production live path — frames submit
    /// asynchronously and the CPU only stalls via `inFlightSemaphore`, letting
    /// frame N+1's setup overlap frame N's GPU work. The live renderer sets this
    /// per scene; defaults to the safe synchronous behavior for any other caller.
    var synchronizeFrameCompletion = true
    /// Cleared `.previous` bootstrap textures, one per (target, size, format).
    /// They are only ever read (seeded before the target's first write of the
    /// frame), so the creation-time clear stays valid for the cache lifetime.
    var bootstrapPreviousTextureCache: [BootstrapPreviousKey: MTLTexture] = [:]
    /// Scratch textures (one per size/format) holding a stable snapshot of the
    /// scene for a pass that reads `.previous` while ALSO writing to the scene.
    var sceneReadHazardSnapshotCache: [BootstrapPreviousKey: MTLTexture] = [:]

    struct BootstrapPreviousKey: Hashable {
        let targetID: WPEMetalTargetID
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }

    /// Present completion handlers run on Metal's callback threads while the
    /// pool is consulted from the render thread, so the in-flight refcounts
    /// live behind a lock in a Sendable box the handler can capture.
    final class PresentInFlightTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [ObjectIdentifier: Int] = [:]

        func increment(_ id: ObjectIdentifier) {
            lock.lock()
            counts[id, default: 0] += 1
            lock.unlock()
        }

        func decrement(_ id: ObjectIdentifier) {
            lock.lock()
            if let count = counts[id], count > 1 {
                counts[id] = count - 1
            } else {
                counts.removeValue(forKey: id)
            }
            lock.unlock()
        }

        func isInFlight(_ id: ObjectIdentifier) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return (counts[id] ?? 0) > 0
        }
    }

    /// Metal resources are thread-safe handles, but `MTLTexture` is not annotated
    /// `Sendable` in the SDK. Present completion runs on Metal callback threads,
    /// so wrap the source texture before capturing it in the `@Sendable` handler.
    struct PresentCompletionTexture: @unchecked Sendable {
        let texture: MTLTexture
    }

    struct MSDFTextPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let colorPixelFormat: UInt
    }

    /// Per-puppet skinning decision for the current frame. `enabled` is false (and `palette` empty)
    /// whenever the validation gate rejects skinning, so the pass renders the static assembled mesh.
    struct PuppetSkinningState {
        let enabled: Bool
        let palette: [simd_float4x4]
        let attachmentsByName: [String: WPEPuppetAttachment]
        /// Parent puppet's RAW MDLS bind-world per bone — the basis the palette (`current · rawBind⁻¹`)
        /// was built on, so `palette · (rawBind · MDAT)` recovers the anchor's CURRENT world position.
        let boneBindByIndex: [Int: simd_float4x4]
        /// Parent puppet's ASSEMBLED bind-world per bone: the frame-0 pose for character-sheet puppets
        /// (raw MDLS is the exploded sheet there), the raw bind for pre-assembled. This is the anchor's
        /// REST position — matching the graph builder's static placement — so the follow adds only the
        /// animated `current − rest` delta (zero at rest) instead of double-counting the assembly.
        let assembledBoneBindByIndex: [Int: simd_float4x4]
        let reason: String
    }

    /// Per-frame attachment/skinning context, built once before the layer loop so a parent puppet's
    /// animated bone palette is available before its attached children render.
    struct PuppetAttachmentFrameContext {
        let layersByObjectID: [String: WPEPreparedRenderLayer]
        let skinningByObjectID: [String: PuppetSkinningState]
        let sceneSize: CGSize
    }

    struct PreviousFrameHistory {
        let sceneSize: CGSize
        let sceneTexture: MTLTexture?
        let namedTextures: [String: MTLTexture]
    }

    fileprivate struct TranslatedPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let vertexName: String
        let fragmentName: String
        let blendMode: String
        let colorPixelFormat: UInt
        let depthPixelFormat: UInt
    }

    init(device: MTLDevice) throws {
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
        // The Swift transpiler is the only Metal-side translator we ship; shaders
        // it can't handle surface as the scene's metalRendererUnsupported load error.
        self.shaderCompiler = WPESwiftShaderCompiler(device: device)
    }

    /// Phase 2E: lets `WPEMetalSceneRenderer` hand the executor's MTLDevice
    /// to `WPEVideoTextureSource` (which needs it to build a
    /// `CVMetalTextureCache`) without exposing the device publicly.
    var textureSourceDevice: MTLDevice {
        device
    }

    /// One-shot guard so the waterwaves dispatch logs its first live execution per renderer
    /// (confirms the builtin effect_waterwaves path actually runs). Internal —
    /// flipped by the waterwaves `bind` closure in `WPEMetalEffectDispatchTable`.
    var loggedWaterWavesDispatch = false
    /// Scene size (ortho-projection pixels) for the frame currently encoding.
    /// Stashed at frame start so `usesObjectQuadGeometry` can judge a
    /// scene-capture utility layer's footprint without threading `sceneSize`
    /// through its dozen call sites. Safe because the render loop encodes one
    /// frame at a time.
    private var currentSceneSize: CGSize = .zero

    // Object IDs that are parents of at least one other layer. A `composelayer`
    // that hosts children is a WPE "layer group" (transform/opacity container),
    // NOT a scene-capture effect box — its children render as flat layers, so its
    // own sub-rect scene passthrough must be suppressed (else it paints a
    // picture-in-picture scene-copy; scene 3632513108's bottom-right control panel).
    private var groupingContainerObjectIDs: Set<String> = []
    /// Logical targets rendered by >1 depth-using pass: their depth may be loaded
    /// across encoders (e.g. a `depthTest:less` pass reading a prior pass's depth),
    /// so they keep persistent depth rather than transient/memoryless. Recomputed
    /// per render from the prepared pipeline.
    private var persistentDepthTargetIDs: Set<WPEMetalTargetID> = []

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
        dynamicTextureNames: Set<String> = [],
        dynamicLayerIDs: Set<String> = [],
        runtimeUniforms: WPEMetalRuntimeUniforms = .zero,
        cameraUniforms: WPEMetalCameraUniforms = .identity,
        sceneID: String? = nil,
        particleSystems: [WPEParticleSystem] = [],
        particleTextures: [ObjectIdentifier: MTLTexture] = [:],
        particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:],
        particleParallax: WPECameraParallaxFrame = .neutral
    ) throws -> MTLTexture {
        // Async submission: take a permit up front so the CPU blocks here (rather
        // than queuing another frame) once `maxFramesInFlight` are outstanding.
        // The matching signal is emitted from the command buffer's completion
        // handler on success; the `defer` releases it on any early throw so a
        // permit is never lost.
        let asyncSubmission = !synchronizeFrameCompletion
        if asyncSubmission {
            // Poll, don't block: a blocking wait here holds the @MainActor
            // (this runs from MTKView.draw, shared across every display) and would
            // stall other displays' draw callbacks, dropping dual-60fps to 30fps.
            // Thrown before the `defer` below is armed, so no stray signal.
            if inFlightSemaphore.wait(timeout: .now()) == .timedOut {
                throw WPEMetalFrameInFlightBudgetExhausted()
            }
        }
        var didCommitAsync = false
        defer { if asyncSubmission && !didCommitAsync { inFlightSemaphore.signal() } }
        #if DEBUG
        scenePassDumps.removeAll()
        // Collect per-pass scene-target snapshots when the workshopID-scoped dump
        // flag matches OR the render oracle is on (which hashes every pass into the
        // trace). Oracle collection forces particles standalone (below) — a render-
        // encoder boundary change only, byte-identical composite, consistent across
        // both before/after oracle runs.
        let dumpScenePasses = (sceneID.map { !$0.isEmpty && UserDefaults.standard.string(forKey: "WPEDumpScenePasses") == $0 } ?? false)
            || WPEOracleMode.perPassHashesEnabled
        dumpLayerPassesID = {
            let id = UserDefaults.standard.string(forKey: "WPEDumpLayerPasses")
            return (id?.isEmpty == false) ? id : nil
        }()
        #endif
        let preparedPipeline = pipeline.addingMetalRuntimeUniforms(runtimeUniforms, camera: cameraUniforms)
        currentOutputPixelFormat = cameraUniforms.sceneHDR
            ? .rgba16Float
            : Self.outputPixelFormat
        targetPool.promotesLDRFormatsToHDR = cameraUniforms.sceneHDR
        let output = try makeOutputTexture(size: size)
        let staticLayerCacheEnabled = Self.isStaticLayerCacheEnabled
        staticLayerCompositeCache.updateBudget(Self.staticLayerCacheBudgetBytes)
        if staticLayerCacheEnabled {
            if staticLayerCacheSceneSize != size {
                invalidateStaticLayerCache()
                staticLayerCacheSceneSize = size
            }
        } else if staticLayerCacheSceneSize != nil {
            invalidateStaticLayerCache()
        }
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

        // Aliasing is disabled while the debug bypass path is active — bypass
        // skips a layer's passes, which would break the lockstep pass index the
        // alias plan relies on.
        let aliasIntervals = fboAliasIntervals(pipeline: preparedPipeline, sceneSize: size)
        targetPool.prepare(pipeline: preparedPipeline, aliasIntervals: aliasIntervals)
        targetPool.beginAliasFrame()
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
            cameraUniforms: cameraUniforms,
            previousSceneTexture: reusableHistory?.sceneTexture,
            previousNamedTextures: reusableHistory?.namedTextures ?? [:],
            // Threaded so `resolve(.fbo)` can zero-fill a declared-but-unwritten
            // local FBO on its first read instead of failing the scene at load.
            renderTargetPool: targetPool
        )
        frameState.cameraParallax = runtimeUniforms.cameraParallax
        currentSceneSize = size
        groupingContainerObjectIDs = Set(preparedPipeline.layers.compactMap { $0.graphLayer.parentObjectID })
        persistentDepthTargetIDs = computePersistentDepthTargetIDs(for: preparedPipeline)
        var didEncode = false
        let attachmentContext = makeAttachmentFrameContext(
            for: preparedPipeline,
            runtimeUniforms: runtimeUniforms,
            sceneSize: size
        )

        // Particles composite at their scene paint index, interleaved between
        // layers: a particle with sortIndex P draws after every layer with a
        // lower sortIndex and before any higher one (background → rain → character).
        let sortedParticles = particleSystems.enumerated()
            .filter { $0.element.liveInstanceCount > 0 }
            .sorted { lhs, rhs in
                lhs.element.sortIndex != rhs.element.sortIndex
                    ? lhs.element.sortIndex < rhs.element.sortIndex
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
        var particleCursor = 0
        // Batch consecutive non-refract systems (same `output`, no intervening
        // scene pass) into ONE render encoder, instead of a render pass + full-target
        // load/store per system. Refract systems need a pre-draw blit snapshot (no
        // open render encoder allowed) and DEBUG per-pass dumping needs a boundary
        // per system → both end the run and render standalone. A run never spans
        // `flushParticles` calls (a layer pass renders between them), so it is closed
        // before returning.
        func flushParticles(before threshold: Int) throws {
            var particleRunEncoder: MTLRenderCommandEncoder?
            func endParticleRun() {
                guard let encoder = particleRunEncoder else { return }
                encoder.endEncoding()
                particleRunEncoder = nil
                frameState.registerWrite(texture: output, targetID: .scene)
            }
            // Close the run on EVERY exit — a thrown `particlePipelineState`/encoder
            // failure mid-run must not leak an open encoder (Metal validation asserts).
            defer { endParticleRun() }
            while particleCursor < sortedParticles.count,
                  sortedParticles[particleCursor].sortIndex < threshold {
                let system = sortedParticles[particleCursor]
                let traceIndex = particleCursor
                particleCursor += 1

                let isRefractSystem = !system.isRope
                    && particleNormalTextures[ObjectIdentifier(system)] != nil
                #if DEBUG
                let standalone = isRefractSystem || dumpScenePasses
                #else
                let standalone = isRefractSystem
                #endif

                if standalone {
                    endParticleRun()
                    if try encodeParticleSystem(
                        system,
                        into: commandBuffer,
                        output: output,
                        sceneSize: size,
                        cameraParallax: particleParallax,
                        texturesByMaterial: particleTextures,
                        normalsByMaterial: particleNormalTextures,
                        frameState: &frameState,
                        traceIndex: traceIndex
                    ) {
                        didEncode = true
                        #if DEBUG
                        // Label MUST equal the trace passId `recordParticlePass`
                        // emits (`particle.<traceIndex>`) so `recordPassOutputs`
                        // matches by id and the flushed snapshot's hash lands on
                        // this pass; the old `.<sortIndex>.` form never matched.
                        captureScenePassIfDumping(dumpScenePasses, label: "particle.\(traceIndex)", output: output, commandBuffer: commandBuffer)
                        #endif
                    }
                    continue
                }

                let encoder = try particleRunEncoder
                    ?? makeParticleOutputEncoder(output: output, commandBuffer: commandBuffer)
                particleRunEncoder = encoder
                if try encodeParticleSystem(
                    system,
                    into: commandBuffer,
                    output: output,
                    sceneSize: size,
                    cameraParallax: particleParallax,
                    texturesByMaterial: particleTextures,
                    normalsByMaterial: particleNormalTextures,
                    frameState: &frameState,
                    traceIndex: traceIndex,
                    sharedEncoder: encoder
                ) {
                    didEncode = true
                }
            }
        }

        // Flattened pass index for FBO aliasing — MUST advance in lockstep with
        // the same `for layer { for pass in layer.passes }` order the alias plan
        // used, across every branch below, or makeAliasable could fire early.
        var aliasPassCounter = 0
        for layer in preparedPipeline.layers {
            try flushParticles(before: layer.graphLayer.sortIndex)
            // Static-layer cache: a provably-static layer's composites are
            // rendered once and reused. On a hit we seed frameState with every
            // cached composite so the layer's `.scene` copy (and any downstream
            // consumer) resolves them, then skip its compose/effect passes.
            let staticCachePlan = staticLayerCacheEnabled
                ? WPEMetalStaticLayerClassifier.cachePlan(
                    for: layer,
                    dynamicTextureNames: dynamicTextureNames,
                    dynamicLayerIDs: dynamicLayerIDs
                )
                : nil
            let cachedStaticLayer = staticCachePlan.flatMap { plan in
                staticLayerCompositeCache.cachedLayer(
                    for: layer.graphLayer.objectID,
                    requiredTargets: Set(plan.cachedTargets.keys)
                )
            }
            if let cachedStaticLayer {
                for (name, texture) in cachedStaticLayer.texturesByTarget {
                    frameState.seedPreviousTexture(texture, targetID: .named(name))
                    frameState.markInitialized(texture)
                }
                if loggedStaticLayerCacheHits.insert(layer.graphLayer.objectID).inserted {
                    Logger.info(
                        "[WPE.static-layer-cache] skip composite layer=\(layer.graphLayer.objectID) targets=\(cachedStaticLayer.texturesByTarget.count) bytes=\(cachedStaticLayer.bytes)",
                        category: .wpeRender
                    )
                }
            }
            // Accumulates first-frame snapshots for a cache miss until all of the
            // plan's targets are captured, then inserts them as one layer entry.
            var pendingStaticSnapshots: [String: MTLTexture] = [:]
            var pendingStaticBytes = 0
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
            for (layerPassIndex, pass) in layer.passes.enumerated() {
                // Advance the alias index for EVERY pass (defer fires endPass at
                // iteration exit, including the hidden-pass `continue` below), so
                // makeAliasable only happens AFTER this pass is encoded. The
                // static-layer skip below keeps this lockstep: it `continue`s
                // AFTER the index advances + defer is armed.
                let passAliasIndex = aliasPassCounter
                aliasPassCounter += 1
                defer { targetPool.endPass(passIndex: passAliasIndex) }
                // Hidden layer: still encode passes that write a composite/FBO
                // (dependents may sample them), but skip the final scene draw so
                // the layer is invisible. Toggling `visible` true re-includes it
                // without a pipeline rebuild. A pass targeting the shared group
                // buffer (`_rt_layerGroup_*`) is a group child's VISIBLE output —
                // the group-child analogue of the scene draw — so skip it too;
                // otherwise a condition-hidden variant kept in the graph for live
                // script toggling paints into the group buffer and overlaps the
                // selected variant (scene 3226487183's mutually-exclusive poses).
                if !graphLayer.visible {
                    switch pass.pass.target {
                    case .scene:
                        didEncode = true
                        continue
                    case .fbo(let name) where WPERenderTargetNames.LayerGroup.matches(name):
                        didEncode = true
                        continue
                    case .layerComposite, .fbo:
                        break
                    }
                }
                // Cache hit: composites are already in `frameState` (seeded above),
                // so skip the compose/effect passes and run only the `.scene` copy
                // (which applies parallax from the cached texture).
                if cachedStaticLayer != nil {
                    switch pass.pass.target {
                    case .scene:
                        break
                    case .layerComposite, .fbo:
                        didEncode = true
                        continue
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
                // First-time miss: snapshot each composite into a persistent
                // texture right after its last producer pass; once every planned
                // target is captured, commit them to the cache as one layer entry.
                if let staticCachePlan, cachedStaticLayer == nil {
                    captureStaticLayerSnapshots(
                        at: layerPassIndex,
                        plan: staticCachePlan,
                        layer: graphLayer,
                        commandBuffer: commandBuffer,
                        frameState: &frameState,
                        snapshots: &pendingStaticSnapshots,
                        bytes: &pendingStaticBytes
                    )
                }
                #if DEBUG
                if dumpScenePasses {
                    // Dump BOTH the scene target and each layer's intermediate composite target, so a
                    // per-layer effect chain (e.g. 840's face → opacity/waterripple/…) can be inspected
                    // pass-by-pass to see exactly which pass drops/moves content.
                    let dumpTarget: MTLTexture?
                    switch pass.pass.target {
                    case .scene:
                        dumpTarget = output
                    case .layerComposite(let name), .fbo(let name):
                        // Use the texture the pass ACTUALLY wrote to (FBO pooling/aliasing means
                        // re-resolving the name by `targetTexture` can vend a different/cleared one).
                        dumpTarget = frameState.latestNamedTextures[name]
                    }
                    if let dumpTarget {
                        captureScenePassIfDumping(dumpScenePasses, label: pass.pass.id, output: dumpTarget, commandBuffer: commandBuffer)
                    }
                }
                #endif
            }
        }

        try flushParticles(before: Int.max)

        guard didEncode else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }

        try encodeSceneBloomIfNeeded(
            cameraUniforms: cameraUniforms,
            output: output,
            commandBuffer: commandBuffer
        )

        recyclePaletteBuffersOnCompletion(of: commandBuffer)
        if asyncSubmission {
            // Bound in-flight depth (signal mirrors the wait above) and surface
            // GPU errors from the handler — they land after we've returned, so we
            // log rather than throw; the wallpaper just renders the next frame.
            // GPU-side ordering on the shared queue still guarantees the text and
            // present buffers (committed later) observe this frame's writes.
            let semaphore = inFlightSemaphore
            let sink = gpuErrorSink
            commandBuffer.addCompletedHandler { cb in
                semaphore.signal()
                // Logged in every build (the old synchronous path threw on error,
                // which the caller logged) so a GPU failure isn't silent in release.
                if cb.status == .error {
                    let detail = cb.error?.localizedDescription ?? "unknown"
                    sink.record("async-frame: \(detail)")
                    Logger.warning(
                        "[WPE async-frame] command buffer error: \(detail)",
                        category: .wpeRender
                    )
                }
            }
            commandBuffer.commit()
            didCommitAsync = true
        } else {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.status == .error {
                gpuErrorSink.record("frame: \(commandBuffer.error?.localizedDescription ?? "unknown")")
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
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

    /// Slots this layout occupies, matching the per-shader `WPEUniforms.vals[]` the transpiler emits.
    /// Slots are assigned sequentially, so the max `slot + slotCount` is the total.
    static func translatedSlotCount(for layout: [WPEUniformSlot]) -> Int {
        max(layout.reduce(0) { Swift.max($0, $1.slot + $1.slotCount) }, 1)
    }

    /// macOS caps `setFragmentBytes` at 4 KB (256 × 16-byte slots). Shaders under that ride the inline
    /// fast path; audio visualizers above it (e.g. a 258-slot oscilloscope) bind a transient shared
    /// buffer instead. The buffer is retained by the command buffer until GPU completion.
    func bindTranslatedUniformSlots(_ slots: [SIMD4<Float>], to encoder: MTLRenderCommandEncoder, index: Int = 0) {
        guard !slots.isEmpty else { return }
        let byteCount = MemoryLayout<SIMD4<Float>>.stride * slots.count
        if byteCount <= 4096 {
            var inline = slots
            encoder.setFragmentBytes(&inline, length: byteCount, index: index)
        } else if let buffer = slots.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: byteCount, options: .storageModeShared)
        }) {
            encoder.setFragmentBuffer(buffer, offset: 0, index: index)
        }
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
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: Self.translatedSlotCount(for: layout))
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
            case "vec2", "ivec2", "bvec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3", "ivec3", "bvec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4", "ivec4", "bvec4":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
            default:
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            }
        }
        return slots
    }

    var textOverlayPipelineCache: [UInt: MTLRenderPipelineState] = [:]

    var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]
    /// Reused scene snapshot storage for REFRACT particle passes; reallocated when
    /// the output size/format changes. A frame-local freshness guard decides
    /// whether the contents can be reused without another full-frame blit.
    var refractionBackground: MTLTexture?

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
        if case .named(let name) = targetID,
           WPERenderTargetNames.LayerGroup.matches(name) {
            return true
        }
        return Self.blendModeRequiresExistingDestination(pass.pass.blending)
    }

    static func blendModeRequiresExistingDestination(_ blendMode: String) -> Bool {
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
             "premultipliedscreen",
             "darken",
             "lighten",
             "multiply",
             "negative",
             "oneone",
             "oneoneone",
             "screen",
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
        let aliasAvoidanceTexture: MTLTexture?
        if readsCurrentTarget {
            aliasAvoidanceTexture = initialPreviousTextureForTarget
                ?? (Self.requiresDiscreteDestinationForSourceAliasing(pass) ? frameState.output : nil)
        } else if Self.requiresDiscreteDestinationForSourceAliasing(pass) {
            aliasAvoidanceTexture = frameState.output
        } else {
            aliasAvoidanceTexture = nil
        }
        let destination = try targetTexture(
            for: pass.pass.target,
            layer: layer,
            frameState: &frameState,
            avoiding: aliasAvoidanceTexture
        )
        let drawLayer = layerForDrawing(pass: pass.pass, layer: layer)

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

        // A pass that reads `.previous` while ALSO targeting the scene would bind
        // `.previous` to `latestSceneTexture` — the SAME live `output` texture it
        // is drawing into (`targetTexture(.scene)` always returns `output`). That
        // read-write feedback is undefined on the GPU: scene 3470764447's rotated
        // `compose source=previous target=scene` card sampled the pixels it was
        // writing, recursing the whole frame into itself and flickering. `.previous`
        // does NOT traverse `snapshotFullFrameBufferIfAliasingScene` (that only
        // covers `_rt_FullFrameBuffer`-style aliases), so snapshot the scene-so-far
        // into a stable scratch here and rebind `.previous` to it. The write still
        // targets `output`; the read is now a frozen frame-before-this-pass image.
        if readsCurrentTarget, case .scene = targetID,
           let prev = previousTextureForTarget,
           ObjectIdentifier(prev) == ObjectIdentifier(destination.texture) {
            let snapshot = try sceneReadHazardSnapshot(
                matching: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(snapshot)
            frameState.seedPreviousTexture(snapshot, targetID: .scene)
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

        if try encodePuppetClipCompositePassIfNeeded(
            pass: pass,
            layer: drawLayer,
            puppetModel: puppetModel,
            skinningState: skinningState,
            destination: destination,
            shouldLoadDestination: shouldLoadExistingAttachment,
            textures: textures,
            commandBuffer: commandBuffer,
            frameState: &frameState
        ) {
            frameState.registerWrite(texture: destination.texture, targetID: destination.id)
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = shouldLoadExistingAttachment ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor(for: targetID)

        if needsDepth {
            let depth = try depthCache.attachmentTexture(
                for: destination,
                frameState: &frameState,
                allowTransient: !persistentDepthTargetIDs.contains(targetID)
            )
            descriptor.depthAttachment.texture = depth
            if depthCache.isTransientDepthAttachment(depth) {
                // Memoryless depth cannot load/store; it's per-pass transient regardless.
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .dontCare
            } else {
                // Depth is keyed independently of the color target (WPEMetalDepthTextureKey)
                // and allocated fresh on first use per frame, so the color's
                // `shouldLoadExistingAttachment` must NOT decide it: a bootstrapped
                // (copy + markInitialized) color paired with a virgin depth texture would
                // otherwise `.load` undefined GPU memory. `.load` only once this exact depth
                // texture has been written earlier this frame.
                let depthInitialized = frameState.hasInitialized(depth)
                descriptor.depthAttachment.loadAction = depthInitialized ? .load : .clear
                descriptor.depthAttachment.storeAction = .store
                frameState.markInitialized(depth)
            }
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
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.appendLog(
                "[renderPassState] pass=\(pass.pass.id) layer=\(layer.objectName) shader=\(pass.pass.shader) "
                    + "target=\(pass.pass.target) blend=\(pass.pass.blending) "
                    + "depthTest=\(pass.pass.depthTest) depthWrite=\(pass.pass.depthWrite) "
                    + "needsDepth=\(needsDepth) cull=\(pass.pass.cullMode)",
                level: .notice
            )
        }

        let drewSceneModel = try encodeSceneModelMaterialPassIfNeeded(
            pass: pass,
            layer: drawLayer,
            puppetModel: puppetModel,
            skinningState: skinningState,
            destination: destination,
            textures: textures,
            frameState: frameState,
            encoder: encoder,
            depthPixelFormat: needsDepth ? .depth32Float : .invalid
        )
        let drewPuppetMaterial: Bool
        if drewSceneModel {
            drewPuppetMaterial = false
        } else {
            drewPuppetMaterial = try encodePuppetMaterialPassIfNeeded(
            pass: pass,
            layer: drawLayer,
            puppetModel: puppetModel,
            skinningState: skinningState,
            runtimeUniforms: runtimeUniforms,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )
        }
        let drewPuppetSceneComposite: Bool
        if drewSceneModel || drewPuppetMaterial {
            drewPuppetSceneComposite = false
        } else {
            drewPuppetSceneComposite = try encodePuppetSceneCompositePassIfNeeded(
                pass: pass,
                layer: drawLayer,
                puppetModel: puppetModel,
                skinningState: skinningState,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )
        }
        if !drewSceneModel && !drewPuppetMaterial && !drewPuppetSceneComposite {
            let dispatcher = WPEMetalShaderDispatcher(executor: self)
            try dispatcher.dispatch(
                pass: pass,
                layer: drawLayer,
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
    func puppetAnimationLayers(
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
        var attachedChildNamesByParent: [String: Set<String>] = [:]
        for layer in pipeline.layers {
            guard let parentID = layer.graphLayer.parentObjectID,
                  let attachment = layer.graphLayer.attachment else { continue }
            attachedChildNamesByParent[parentID, default: []].insert(attachment)
        }
        // The objectID→layer index is only ever read to resolve a child's parent
        // puppet in `layerApplyingAttachmentFollow`; a scene with no attached
        // children never touches it, so skip building it there.
        let layersByID: [String: WPEPreparedRenderLayer] = attachedChildNamesByParent.isEmpty
            ? [:]
            : Dictionary(
                pipeline.layers.map { ($0.graphLayer.objectID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        var skinningByObjectID: [String: PuppetSkinningState] = [:]
        for layer in pipeline.layers {
            guard let model = layer.puppetModel else { continue }
            skinningByObjectID[layer.graphLayer.objectID] = validatedSkinningState(
                for: layer.graphLayer,
                model: model,
                attachedChildNames: attachedChildNamesByParent[layer.graphLayer.objectID] ?? [],
                time: runtimeUniforms.time
            )
        }
        recordPuppetSkinningBreadcrumbs(pipeline: pipeline, skinningByObjectID: skinningByObjectID)
        return PuppetAttachmentFrameContext(
            layersByObjectID: layersByID,
            skinningByObjectID: skinningByObjectID,
            sceneSize: sceneSize
        )
    }

    /// Per-objectID dedup so the skinning-gate reason logs once per change, not per frame.
    /// Reset on graph rebuild so every scene load leaves one breadcrumb per puppet.
    var lastLoggedPuppetSkinningReason: [String: String] = [:]

    /// Gate validation runs per frame, so its two expensive pieces memoize per objectID (reset on
    /// graph rebuild via `releaseTransientResources`, since a reload can reuse an objectID for a
    /// different puppet):
    /// - the clip-wide displacement scan (6 palette evaluations) is time-independent given the
    ///   animation-layer stack, keyed by that stack's signature;
    /// - the per-frame palette evaluation quantizes time to discrete sampled frames
    ///   (`sampledFrameIndex`), so an unchanged (stack, sampled-frames) signature reproduces the
    ///   palette bit-exactly and the evaluation is skipped (~60fps render vs ~24-30fps clips).
    var characterSheetWarnedReasonByObjectID: [String: String] = [:]
    struct PuppetBoundScanCacheEntry {
        let stackSignature: [UInt64]
        let detail: String?
    }
    var puppetBoundScanDetailByObjectID: [String: PuppetBoundScanCacheEntry] = [:]
    struct PuppetPaletteCacheEntry {
        let frameSignature: [UInt64]
        let evaluation: WPEPuppetPaletteEvaluation
    }
    var puppetPaletteCacheByObjectID: [String: PuppetPaletteCacheEntry] = [:]

    /// Cache-hit counters proving the memoization actually short-circuits (a recompute-only path
    /// would still pass the output-equality tests). Production cost is one Int increment.
    var puppetPaletteCacheHitsForTesting = 0
    var puppetBoundScanCacheHitsForTesting = 0

    /// Recycles bone-palette buffers across frames instead of `makeBuffer` per draw. Buffers are
    /// power-of-two bucketed so puppets with different bone counts share them; the shader only reads
    /// `paletteCount` entries (`indices < paletteCount` guards every tap), so a bucket's stale tail is
    /// never sampled. Lock-protected: `recycle` runs on Metal completion threads.
    final class PuppetBonePaletteBufferPool: @unchecked Sendable {
        private let lock = NSLock()
        private var freeBuffersByLength: [Int: [MTLBuffer]] = [:]
        /// Frames in flight are semaphore-bounded, so a scene needs at most a few buffers per
        /// puppet; anything beyond this per bucket is released rather than hoarded.
        private let maxFreePerLength = 8

        func acquire(byteCount: Int, device: MTLDevice) -> MTLBuffer? {
            let length = Self.bucketLength(for: byteCount)
            lock.lock()
            let reused = freeBuffersByLength[length]?.popLast()
            lock.unlock()
            return reused ?? device.makeBuffer(length: length, options: [])
        }

        func recycle(_ buffers: [MTLBuffer]) {
            guard !buffers.isEmpty else { return }
            lock.lock()
            for buffer in buffers where (freeBuffersByLength[buffer.length]?.count ?? 0) < maxFreePerLength {
                freeBuffersByLength[buffer.length, default: []].append(buffer)
            }
            lock.unlock()
        }

        func drain() {
            lock.lock()
            freeBuffersByLength.removeAll()
            lock.unlock()
        }

        private static func bucketLength(for byteCount: Int) -> Int {
            var length = 256
            while length < byteCount { length <<= 1 }
            return length
        }
    }

    let bonePaletteBufferPool = PuppetBonePaletteBufferPool()
    /// Palette buffers bound while encoding the current frame; handed to the frame command buffer's
    /// completion handler at commit so they return to the pool only after the GPU has consumed them.
    /// A frame aborted before commit leaves its buffers here — they ride along with the next commit
    /// (never executed by the GPU, so recycling them late is safe, early would be too).
    var bonePaletteBuffersInFlight: [MTLBuffer] = []

    /// Puppet mesh vertex/index topology is immutable for the scene's lifetime (skinning is applied
    /// per-frame in the vertex shader via the bone palette, not by re-baking geometry), so the GPU
    /// buffers are built once per mesh and reused every frame. Dropped on reload via
    /// `releaseTransientResources`.
    struct PuppetMeshBufferKey: Hashable {
        let materialPath: String
        let clipMaskName: String?
        // Full arrays (COW references, no copy): distinct meshes that share material,
        // counts and part layout must still get their own GPU buffers.
        let vertices: [WPEPuppetVertex]
        let indices: [UInt16]
        let parts: [WPEPuppetMeshPart]
    }
    struct PuppetMeshBuffers {
        let vertex: MTLBuffer
        let index: MTLBuffer
    }
    var puppetMeshBufferCache: [PuppetMeshBufferKey: PuppetMeshBuffers] = [:]

    /// See `PresentCompletionTexture`: `MTLBuffer` handles are thread-safe but not `Sendable`-annotated.
    struct PaletteBufferRecycleBatch: @unchecked Sendable {
        let buffers: [MTLBuffer]
    }

    /// Breaks the `_rt_*` scene-alias hazard.
    private func snapshotFullFrameBufferIfAliasingScene(
        pass: WPEPreparedRenderPass,
        destinationTexture: MTLTexture,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        // Any pass sampling a scene alias participates — not only scene-target
        // draws. WPE re-captures the frame (CopyResource) for EVERY layer that
        // samples it, so a snapshot taken for one layer goes stale as soon as
        // later layers draw to the scene. 3521337568: the shine chain captured
        // at pass 48, then the fullscreen filmgrain layer (a layerComposite-target
        // copy at pass 63) reused that capture and its full-frame redraw erased
        // the beams/halo/shine drawn in between.
        func needsSnapshot(_ name: String) -> Bool {
            // A real same-frame render target (has a texture but no snapshot
            // marker — e.g. a chain rendering INTO `_rt_HalfFrameBuffer`) owns
            // its content; never overwrite it with a scene capture.
            if frameState.latestNamedTextures[name] != nil,
               frameState.sceneAliasSnapshotGenerations[name] == nil {
                return false
            }
            // Snapshot on the first reference this frame, or whenever a later
            // scene write made the previous capture stale.
            return frameState.sceneAliasSnapshotGenerations[name] != frameState.sceneWriteGeneration
        }

        var seen = Set<String>()
        for reference in textureReferences(for: pass) {
            guard case .fbo(let alias) = reference,
                  WPEMetalShaderInputs.isSceneAliasName(alias),
                  seen.insert(alias).inserted,
                  needsSnapshot(alias) else {
                continue
            }
            let snapshot = try targetPool.texture(
                for: .fbo(name: alias),
                layer: layer,
                sceneSize: frameState.sceneSize,
                avoiding: destinationTexture
            )
            if let source = frameState.currentFrameSceneTexture {
                try copyTexture(source, to: snapshot, commandBuffer: commandBuffer)
            } else {
                try clearTexture(snapshot, color: clearColor(for: .scene), commandBuffer: commandBuffer)
            }
            frameState.markInitialized(snapshot)
            frameState.latestNamedTextures[alias] = snapshot
            frameState.sceneAliasSnapshotGenerations[alias] = frameState.sceneWriteGeneration
        }
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
    func copyTexture(
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
        // (Plain full-frame layers routed through this fullscreen copy don't
        // parallax — see the camera-parallax limitations note.) The copy
        // fragment samples 1:1 and takes no fragment uniform buffer.
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

    /// True when this pass is WPE `effects/skew` in MODE=1 (Vertex): the quad
    /// geometry must be displaced in the vertex stage (the fragment leaves the UV
    /// untouched in MODE=1, so a fragment-only transpile drops the effect
    /// entirely). MODE=0 (UV) is handled by the ordinary transpiled fragment.
    func isVertexSkewPass(_ pass: WPEPreparedRenderPass) -> Bool {
        let shader = pass.pass.shader
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard shader == "effects/skew" || shader.hasSuffix("/effects/skew") else {
            return false
        }
        let mode = pass.comboValues["MODE"] ?? pass.pass.combos["MODE"] ?? 0
        guard mode == 1 else { return false }
        let params = vertexSkewParams(for: pass)
        // All-zero params = skew disabled → keep the plain object quad.
        return params.topBottomLeftRight != SIMD4<Float>(repeating: 0)
    }

    /// The MODE=1 skew corner-displacement params (top/bottom/left/right) as
    /// fractions of the quad extent, read from the pass material values. WPE's
    /// `skew.vert` multiplies the displacement by `g_TextureReductionScale`
    /// (`textureScale = g_Texture0Resolution.zw * g_TextureReductionScale`), so it
    /// is folded in here — it defaults to 1.0 (full resolution), which is the case
    /// for the FBO-composite textures skew effects sample.
    func vertexSkewParams(for pass: WPEPreparedRenderPass) -> WPESkewParams {
        func value(_ names: [String], default fallback: Float = 0) -> Float {
            for name in names {
                if let v = pass.uniformValues[name] ?? pass.pass.constants[name] {
                    return Self.scalarValue(v, default: fallback)
                }
            }
            let lowered = Set(names.map { $0.lowercased() })
            if let match = pass.uniformValues.first(where: { lowered.contains($0.key.lowercased()) })
                ?? pass.pass.constants.first(where: { lowered.contains($0.key.lowercased()) }) {
                return Self.scalarValue(match.value, default: fallback)
            }
            return fallback
        }
        let reductionScale = value(["textureReductionScale", "g_TextureReductionScale"], default: 1)
        return WPESkewParams(topBottomLeftRight: reductionScale * SIMD4<Float>(
            value(["top", "g_Top"]),
            value(["bottom", "g_Bottom"]),
            value(["left", "g_Left"]),
            value(["right", "g_Right"])
        ))
    }

    func usesObjectQuadGeometry(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        cameraParallax: WPECameraParallaxFrame = .neutral
    ) -> Bool {
        if isGroupRenderTarget(pass.pass.target, layer: layer) {
            return true
        }
        guard case .scene = pass.pass.target else { return false }
        if layer.geometry == .identity {
            // Identity full-frame layers normally take the fullscreen copy path.
            // Route them through the object quad (an identical full-scene quad)
            // only when there's an actual parallax shift to apply, leaving the
            // common no-parallax path byte-for-byte unchanged.
            return layer.parallaxDepth != SIMD2<Double>(0, 0) && cameraParallax.smoothed != SIMD2<Float>(0, 0)
        }
        // WPE fullscreen/passthrough utility layers (project/fullscreen and
        // oversized compose) capture + copy the full frame 1:1. A plain
        // `composelayer.json` authored into a safe sub-rect captures the
        // matching scene area into its layer composite, then its final scene
        // output is confined to that box via the object quad.
        if WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath(layer.imagePath) {
            if layer.groupCompositeSource != nil { return true }
            return sceneCaptureUtilityOutputGeometry(for: layer) == .subregion
        }
        return true
    }

    func sceneCaptureUtilityOutputGeometry(
        for layer: WPERenderLayer
    ) -> WPEMetalSceneCaptureUtilityModels.OutputGeometry {
        guard WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath(layer.imagePath) else {
            return .fullscreen
        }
        // A compose layer that parents children is a layer-group container, not
        // a scene-effect box: its children render flat, so confining its own
        // passthrough to the authored box would paint a scene-copy PiP. Keep it
        // fullscreen (identity passthrough = invisible).
        if groupingContainerObjectIDs.contains(layer.objectID) { return .fullscreen }
        return WPEMetalSceneCaptureUtilityModels.outputGeometry(
            path: layer.imagePath,
            geometry: layer.geometry,
            sceneSize: currentSceneSize
        )
    }

    func isGroupRenderTarget(_ target: WPERenderTarget, layer: WPERenderLayer) -> Bool {
        guard case .fbo(let name) = target else { return false }
        return name == layer.groupRenderTarget
    }

    func objectQuadSceneSize(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: WPEMetalFrameState
    ) -> CGSize {
        guard isGroupRenderTarget(pass.pass.target, layer: layer) else {
            return frameState.sceneSize
        }
        return CGSize(width: destination.texture.width, height: destination.texture.height)
    }

    func objectQuadCameraUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        frameState: WPEMetalFrameState
    ) -> WPEMetalCameraUniforms {
        isGroupRenderTarget(pass.pass.target, layer: layer) ? .identity : frameState.cameraUniforms
    }

    func objectQuadUniforms(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame = .neutral,
        sourceTexture: MTLTexture,
        cameraUniforms: WPEMetalCameraUniforms = .identity
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
            let uniforms = WPEObjectQuadUniforms(
                centerAndSize: SIMD4<Float>(parallax.x, parallax.y, sceneWidth, sceneHeight),
                sceneSizeAndRotation: SIMD4<Float>(sceneWidth, sceneHeight, 0, 0),
                uvSignAndPadding: SIMD4<Float>(1, 1, 0, 0)
            )
            recordObjectQuadDebug(
                layer: layer,
                sourceTexture: sourceTexture,
                cameraUniforms: cameraUniforms,
                uniforms: uniforms,
                path: "identity"
            )
            return uniforms
        }
        if cameraUniforms.usesPerspectiveProjection,
           let projected = perspectiveObjectQuadUniforms(
            for: layer,
            sceneWidth: sceneWidth,
            sceneHeight: sceneHeight,
            cameraParallax: cameraParallax,
            sourceTexture: sourceTexture,
            cameraUniforms: cameraUniforms
           ) {
            recordObjectQuadDebug(
                layer: layer,
                sourceTexture: sourceTexture,
                cameraUniforms: cameraUniforms,
                uniforms: projected,
                path: "perspective"
            )
            return projected
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
        let uniforms = WPEObjectQuadUniforms(
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
        recordObjectQuadDebug(
            layer: layer,
            sourceTexture: sourceTexture,
            cameraUniforms: cameraUniforms,
            uniforms: uniforms,
            path: cameraUniforms.usesPerspectiveProjection ? "perspective-fallback" : "orthographic"
        )
        return uniforms
    }

    private func perspectiveObjectQuadUniforms(
        for layer: WPERenderLayer,
        sceneWidth: Float,
        sceneHeight: Float,
        cameraParallax: WPECameraParallaxFrame,
        sourceTexture: MTLTexture,
        cameraUniforms: WPEMetalCameraUniforms
    ) -> WPEObjectQuadUniforms? {
        let geometry = layer.geometry
        let sceneSize = CGSize(width: CGFloat(sceneWidth), height: CGFloat(sceneHeight))
        guard let projection = cameraUniforms.projectedCenterInScenePixels(
            worldPoint: geometry.origin,
            sceneSize: sceneSize
        ) else { return nil }
        let baseWidth = Float(geometry.size?.width ?? CGFloat(sourceTexture.width))
        let baseHeight = Float(geometry.size?.height ?? CGFloat(sourceTexture.height))
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let width = max(baseWidth * max(abs(scaleX), 0.0001) * projection.depthScale, 0.0001)
        let height = max(baseHeight * max(abs(scaleY), 0.0001) * projection.depthScale, 0.0001)
        let quadCenter = projection.center
            + Self.alignmentCenterOffset(alignment: geometry.alignment, width: width, height: height)
            + cameraParallax.pixelOffset(depth: layer.parallaxDepth, sceneSize: sceneSize)
        return WPEObjectQuadUniforms(
            centerAndSize: SIMD4<Float>(quadCenter.x, quadCenter.y, width, height),
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

    /// A DIRECTDRAW `shape: "quad"` layer draws through the 4-corner geometry
    /// (light beams etc.), not the axis-aligned object quad. Gated to the
    /// orthographic scene draw — the corners are pre-projected here so a live
    /// perspective camera falls back to the object quad.
    func usesShapeQuadGeometry(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        frameState: WPEMetalFrameState
    ) -> Bool {
        guard let points = layer.geometry.shapePoints, points.count == 4 else { return false }
        guard case .scene = pass.pass.target else { return false }
        return !frameState.cameraUniforms.usesPerspectiveProjection
    }

    /// Builds the four perspective-quad corners for a shape-quad layer. Each WPE
    /// point maps to a model-space corner `((p.x-0.5)·H, (0.5-p.y)·H)` in a square
    /// base of the scene height, then the layer scale/rotation/origin/parallax are
    /// applied — identical to how the object quad places its rectangle, so a
    /// unit-square set of points reduces to the object-quad rectangle. Corners are
    /// emitted in triangle-strip order (p0, p1, p3, p2) and carry the point value
    /// as the UV for the fragment perspective reconstruction.
    func shapeQuadUniforms(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame = .neutral
    ) -> WPEShapeQuadUniforms {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        // `usesShapeQuadGeometry` gates every real call to exactly 4 points; the
        // fallback keeps this total for a defensive/future caller (degenerate
        // zero-area quad = draws nothing rather than crashing on an index).
        guard let points = geometry.shapePoints, points.count == 4 else {
            return WPEShapeQuadUniforms(
                corner0: SIMD4<Float>(0, 0, 0, 0),
                corner1: SIMD4<Float>(0, 0, 0, 0),
                corner2: SIMD4<Float>(0, 0, 0, 0),
                corner3: SIMD4<Float>(0, 0, 0, 0),
                sceneHalfAndPad: SIMD4<Float>(sceneWidth * 0.5, sceneHeight * 0.5, 0, 0)
            )
        }
        let baseSquare = sceneHeight
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let rotation = Float(geometry.angles.z)
        let cosR = cos(rotation)
        let sinR = sin(rotation)

        let originX = Float(geometry.origin.x)
        let originY = Float(geometry.origin.y)
        let originXPixels = (originX >= 0 && originX <= 1) ? originX * sceneWidth : originX
        let originYPixels = (originY >= 0 && originY <= 1) ? originY * sceneHeight : originY
        let center = SIMD2<Float>(
            originXPixels - sceneWidth * 0.5,
            originYPixels - sceneHeight * 0.5
        ) + cameraParallax.pixelOffset(depth: layer.parallaxDepth, sceneSize: sceneSize)

        func corner(_ point: SIMD2<Double>) -> SIMD4<Float> {
            let model = SIMD2<Float>(
                (Float(point.x) - 0.5) * baseSquare,
                (0.5 - Float(point.y)) * baseSquare
            )
            let scaled = SIMD2<Float>(model.x * scaleX, model.y * scaleY)
            let rotated = SIMD2<Float>(
                cosR * scaled.x - sinR * scaled.y,
                sinR * scaled.x + cosR * scaled.y
            )
            let scenePixels = center + rotated
            return SIMD4<Float>(scenePixels.x, scenePixels.y, Float(point.x), Float(point.y))
        }

        // Triangle-strip order (p0, p1, p3, p2) matches `wpe_object_quad_vertex`'s
        // TL,TR,BL,BR corner sequence so the two triangles tile the convex quad.
        let p0 = points[0]
        let p1 = points[1]
        let p2 = points[2]
        let p3 = points[3]
        return WPEShapeQuadUniforms(
            corner0: corner(p0),
            corner1: corner(p1),
            corner2: corner(p3),
            corner3: corner(p2),
            sceneHalfAndPad: SIMD4<Float>(sceneWidth * 0.5, sceneHeight * 0.5, 0, 0)
        )
    }

    private func recordObjectQuadDebug(
        layer: WPERenderLayer,
        sourceTexture: MTLTexture,
        cameraUniforms: WPEMetalCameraUniforms,
        uniforms: WPEObjectQuadUniforms,
        path: String
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        let origin = layer.geometry.origin
        let scale = layer.geometry.scale
        WPESceneDebugArtifacts.shared.appendLog(
            "[objectQuad] path=\(path) perspective=\(cameraUniforms.usesPerspectiveProjection) "
                + "layer=\(layer.objectName) id=\(layer.objectID) "
                + "origin=(\(origin.x),\(origin.y),\(origin.z)) scale=(\(scale.x),\(scale.y),\(scale.z)) "
                + "source=\(sourceTexture.width)x\(sourceTexture.height) "
                + "center=(\(uniforms.centerAndSize.x),\(uniforms.centerAndSize.y)) "
                + "size=(\(uniforms.centerAndSize.z),\(uniforms.centerAndSize.w))",
            level: .notice
        )
    }

    static func alignmentCenterOffset(
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
              let snapshot = makeDebugSnapshotTexture(
                  width: output.width,
                  height: output.height,
                  pixelFormat: output.pixelFormat
              ),
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

    private func makeDebugSnapshotTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "WPE Metal debug pass snapshot"
        return texture
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

    /// Phase 2D-D: pack scene uniforms for the genericimage* built-ins.
    /// Developer-only image brightness/color diagnostic; gated by its own key so it
    /// is independent of the unrelated audio-reactive DSP log toggle.
    private static let imageUniformDebugEnabled = UserDefaults.standard.bool(forKey: "WPEImageUniformDebugLog")
    nonisolated(unsafe) private static var loggedImageUniformNames = Set<String>()

    func genericImageUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasMask: Bool,
        sourceTexture: MTLTexture? = nil,
        maskTexture: MTLTexture? = nil
    ) -> WPEGenericImageUniforms {
        let color = WPEMetalShaderInputs.colorVector(for: pass)
        let gAlpha = WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1)
        let gBrightness = WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1)
        let alpha = gAlpha * Float(layer.geometry.alpha)
        let brightness = gBrightness * Float(layer.geometry.brightness)
        let sourceUVScale = Self.logicalUVScale(for: sourceTexture)
        let maskUVScale = Self.logicalUVScale(for: maskTexture)
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.appendLog(
                "[imageUniform] layer=\(layer.objectName) id=\(layer.objectID) shader=\(pass.pass.shader) "
                    + "color=(\(color.x),\(color.y),\(color.z),\(color.w)) "
                    + "gAlpha=\(gAlpha) layerAlpha=\(layer.geometry.alpha) alpha=\(alpha) "
                    + "gBrightness=\(gBrightness) layerBrightness=\(layer.geometry.brightness) brightness=\(brightness) "
                    + "hasMask=\(hasMask) "
                    + "uvScale0=(\(sourceUVScale.x),\(sourceUVScale.y)) "
                    + "uvScale1=(\(maskUVScale.x),\(maskUVScale.y))",
                level: .notice
            )
        }
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
            alphaMaskUV: SIMD4<Float>(alpha, brightness, hasMask ? 1 : 0, 0),
            textureUVScale: SIMD4<Float>(
                sourceUVScale.x,
                sourceUVScale.y,
                maskUVScale.x,
                maskUVScale.y
            )
        )
    }

    /// generic4 scene-model material constants → fragment uniforms. Material
    /// bindings use the shader-annotation names ("color" → g_TintColor,
    /// "emissivecolor" → g_EmissiveColor…), NOT the g_* uniform names, and WPE
    /// uploads them RAW (no sRGB conversion — RenderDoc-verified). The emissive
    /// term requires BOTH the slot-2 component map and authored emissive
    /// constants: WPE's EMISSIVE_MAP combo is baked by the editor from the mask
    /// asset, which we can't read, so authored intent is the safe gate.
    func sceneModelGenericUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasComponentMap: Bool
    ) -> WPESceneModelGenericUniforms {
        func constantVector3(_ names: [String], default def: SIMD3<Float>) -> SIMD3<Float> {
            for name in names {
                if let v = pass.pass.constants[name]?.vectorValue, v.count >= 3 {
                    return SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2]))
                }
            }
            return def
        }
        func constantScalar(_ names: [String], default def: Float) -> Float {
            for name in names {
                if let v = pass.pass.constants[name]?.numberValue {
                    return Float(v)
                }
            }
            return def
        }
        func mergedVector3(_ name: String, default def: SIMD3<Float>) -> SIMD3<Float> {
            guard let v = pass.uniformValues[name]?.vectorValue, v.count >= 3 else { return def }
            return SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2]))
        }

        let tint = constantVector3(["color", "g_TintColor"], default: SIMD3<Float>(1, 1, 1))
        let tintAlpha = constantScalar(["alpha", "Alpha", "g_TintAlpha"], default: 1)
            * Float(layer.geometry.alpha)
        let emissiveColor = constantVector3(["emissivecolor", "g_EmissiveColor"], default: SIMD3<Float>(1, 1, 1))
        let emissiveBrightness = constantScalar(["emissivebrightness", "g_EmissiveBrightness"], default: 1)
        let brightness = constantScalar(["brightness", "g_Brightness"], default: 1)
            * Float(layer.geometry.brightness)
        let ambient = mergedVector3("g_LightAmbientColor", default: SIMD3<Float>(1, 1, 1))
        let skylight = mergedVector3("g_LightSkylightColor", default: SIMD3<Float>(1, 1, 1))
        let lightingEnabled = (pass.pass.combos["LIGHTING"] ?? 1) != 0
        let hdr = (pass.uniformValues["g_SceneHDREnabled"]?.numberValue ?? 0) > 0.5
        let emissiveAuthored = pass.pass.constants["emissivecolor"] != nil
            || pass.pass.constants["emissivebrightness"] != nil
        let emissiveMapActive = hasComponentMap && emissiveAuthored

        return WPESceneModelGenericUniforms(
            tintColorAlpha: SIMD4<Float>(tint.x, tint.y, tint.z, tintAlpha),
            emissive: SIMD4<Float>(emissiveColor.x, emissiveColor.y, emissiveColor.z, emissiveBrightness),
            // No per-vertex normals in the mesh path — evaluate the vertex
            // hemisphere mix(skylight, ambient, N·up*0.5+0.5) at its midpoint.
            ambientLighting: SIMD4<Float>(
                (skylight.x + ambient.x) * 0.5,
                (skylight.y + ambient.y) * 0.5,
                (skylight.z + ambient.z) * 0.5,
                lightingEnabled ? 1 : 0
            ),
            brightnessFlags: SIMD4<Float>(brightness, emissiveMapActive ? 1 : 0, hdr ? 1 : 0, 0)
        )
    }

    // MARK: - Scene HDR bloom

    /// Kill switch: `defaults write Taijia.LiveWallpaper WPEMetalSceneBloomEnabled -bool NO`.
    static let isSceneBloomEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalSceneBloomEnabled") as? Bool) ?? true

    var bloomLevelTextures: [MTLTexture] = []
    /// Backs `bloomLevelTextures` from one placement heap (same `.tracked` mechanism as the FBO
    /// aliasing pool) so the whole pyramid's memory is reclaimed in a single drop on reload. The
    /// pyramid is regenerated from the scene output every frame, so it needs no cross-frame content
    /// persistence — only the allocation is reused until the resolution/level count changes.
    var bloomLevelHeap: MTLHeap?
    var bloomLevelBaseWidth = 0
    var bloomLevelBaseHeight = 0
    var bloomLevelPixelFormat: MTLPixelFormat = .invalid
    var bloomLevelRequestedCount = 0

    private static func logicalUVScale(for texture: MTLTexture?) -> SIMD2<Float> {
        guard let texture else { return SIMD2<Float>(1, 1) }
        let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
        let scaleX = Float(resolution.imageWidth) / Float(max(resolution.textureWidth, 1))
        let scaleY = Float(resolution.imageHeight) / Float(max(resolution.textureHeight, 1))
        return SIMD2<Float>(
            min(max(scaleX, 0), 1),
            min(max(scaleY, 0), 1)
        )
    }

    static func requiresDiscreteDestinationForSourceAliasing(_ pass: WPEPreparedRenderPass) -> Bool {
        let shaderName = pass.pass.shader.lowercased()
        return shaderName == BuiltinShaderName.godraysCombine
            || shaderName.hasSuffix("/" + BuiltinShaderName.godraysCombine)
    }

    func passReadsCurrentTarget(_ pass: WPEPreparedRenderPass, targetID: WPEMetalTargetID) -> Bool {
        func reads(_ reference: WPETextureReference) -> Bool {
            switch (reference, targetID) {
            case (.previous, _):
                return true
            case (.fbo(let name), .named(let targetName)):
                return name == targetName
            default:
                return false
            }
        }
        return reads(pass.pass.source)
            || pass.pass.textures.values.contains(where: reads)
            || pass.pass.binds.values.contains(where: reads)
            || pass.textureBindings.values.contains(where: reads)
    }

    func textureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
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

    /// One translated-shader pipeline combo to pre-compile off the render thread.
    /// `@unchecked Sendable`: the Metal handles it carries (device, library, functions)
    /// are all documented thread-safe — this lets the whole request cross into the
    /// prewarm task group as one Sendable value, so no bare `MTLDevice` is captured.
    struct WPETranslatedPipelinePrewarm: @unchecked Sendable {
        let device: MTLDevice
        let result: WPEShaderCompileResult
        let vertexName: String?
        let blendMode: String
        let colorPixelFormat: MTLPixelFormat
        let depthPixelFormat: MTLPixelFormat
    }

    /// Opaque, `Sendable` result of an off-thread pipeline pre-compile — wraps the private
    /// cache key so the renderer can carry it across the task boundary and hand it back to
    /// `seedTranslatedPipelines` without seeing the key type.
    struct WPEPrewarmedPipeline: @unchecked Sendable {
        fileprivate let key: TranslatedPipelineKey
        fileprivate let state: MTLRenderPipelineState
    }

    /// Pure, thread-safe pipeline compile — mirrors `translatedPipelineState`'s descriptor
    /// construction but does NO cache mutation, so it runs concurrently off-actor in the
    /// prewarm task group. A pipeline is FULLY determined by its cache key, so a prewarmed
    /// state is byte-identical to the lazy one — an imperfect (format/vertex) prediction
    /// only costs a cache miss (the render thread rebuilds that one), never correctness.
    /// Returns nil to skip (missing function / compile failure); the real first-frame render
    /// re-hits and records it as today.
    nonisolated static func buildTranslatedPipeline(
        _ prewarm: WPETranslatedPipelinePrewarm
    ) -> WPEPrewarmedPipeline? {
        let result = prewarm.result
        let resolvedVertexName = prewarm.vertexName ?? result.vertexFunctionName
        let key = TranslatedPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            vertexName: resolvedVertexName,
            fragmentName: result.fragmentFunctionName,
            blendMode: prewarm.blendMode.lowercased(),
            colorPixelFormat: prewarm.colorPixelFormat.rawValue,
            depthPixelFormat: prewarm.depthPixelFormat.rawValue
        )
        guard let vertex = result.library.makeFunction(name: resolvedVertexName)
            ?? prewarm.device.makeDefaultLibrary()?.makeFunction(name: resolvedVertexName),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else { return nil }
        colorAttachment.pixelFormat = prewarm.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = prewarm.depthPixelFormat
        applyBlendMode(prewarm.blendMode.lowercased(), to: colorAttachment)
        guard let state = try? prewarm.device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        return WPEPrewarmedPipeline(key: key, state: state)
    }

    /// Seed pre-compiled pipeline states built by the parallel prewarm. Synchronous and
    /// isolation-free (called on the render context before the first frame), so it never
    /// sends the non-`Sendable` executor across an await. Idempotent: never overwrites a
    /// key the render thread already built.
    func seedTranslatedPipelines(_ prewarmed: [WPEPrewarmedPipeline]) {
        for entry in prewarmed where translatedPipelineCache[entry.key] == nil {
            translatedPipelineCache[entry.key] = entry.state
        }
    }

    /// Phase 2D-H: pack a runtime uniform buffer matching the layout the transpiler emitted (every uniform takes 1-4 float4 slots).
    func packTranslatedUniforms(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot],
        texturesBySlot: [Int: MTLTexture] = [:],
        destinationTexture: MTLTexture? = nil
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: Self.translatedSlotCount(for: layout))
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
            case "vec2", "ivec2", "bvec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3", "ivec3", "bvec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4", "ivec4", "bvec4":
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
        case "premultipliedscreen", "screen":
            // Premultiplied source: src + dst·(1−src) ≡ WPE's alpha-weighted
            // screen mix(dst, screen(dst,src), a) — black pixels leave dst intact.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

    /// Run the WPE preprocessor + `WPESwiftShaderCompiler` over the given prepared pass.
    /// Build the deterministic, runtime-independent compile request for a custom-shader
    /// pass — the cheap preprocess half of `compileCustomShader`, factored out so the
    /// off-thread pre-warm computes the IDENTICAL `translationCacheKey` (a load-time warm
    /// then guarantees a first-frame cache hit). Returns nil for built-in / shader-less
    /// passes. `recordFailure` gates the scene-debug artifact so the warm stays silent and
    /// the real first-frame render remains the sole recorder. Static + value-only inputs so
    /// the warm can call it off the main actor without capturing the executor.
    static func makeCompileRequest(
        for pass: WPEPreparedRenderPass,
        recordFailure: Bool
    ) throws -> WPEShaderCompileRequest? {
        guard let program = pass.shader, !program.isBuiltin else { return nil }
        // The null include-resolver is load-bearing: program.*Source is already
        // #include-expanded at graph-build time (WPERenderPipelineBuilder.preprocess),
        // so a real resolver here could diverge the cache key. Keep it nil.
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let premultipliedInputSlots = premultipliedInputSlots(for: pass)
        let premultipliedOutput = usesPremultipliedOutput(blendMode: pass.pass.blending)
        do {
            return try processor.process(
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
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: program.name,
                    originalVertex: program.vertexSource,
                    processedVertex: nil,
                    originalFragment: program.fragmentSource,
                    processedFragment: nil,
                    translatedMSL: nil,
                    errorText: "preprocess failed: \(String(describing: error))"
                )
            }
            throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                name: program.name,
                reason: String(describing: error)
            )
        }
    }

    func compileCustomShader(
        for pass: WPEPreparedRenderPass
    ) throws -> WPEShaderCompileResult {
        guard let program = pass.shader else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }
        // Hot path: a previously-translated pass returns without re-running the
        // GLSL preprocessor (which `makeCompileRequest` would otherwise do every
        // frame just to recompute the content cache key).
        if let cached = compiledShaderResultByPassID[pass.id] {
            return cached
        }
        do {
            guard let request = try Self.makeCompileRequest(for: pass, recordFailure: true) else {
                throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
            }
            if let cached = translatedShaderCache[request.translationCacheKey] {
                compiledShaderResultByPassID[pass.id] = cached
                return cached
            }
            do {
                let result = try shaderCompiler.compile(request)
                translatedShaderCache[request.translationCacheKey] = result
                compiledShaderResultByPassID[pass.id] = result
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
        } catch {
            // Surface every custom-shader failure (preprocess OR compile) in the
            // scene diagnostic log: the WPESceneDebugArtifacts dump above is
            // hard-off in Release, so otherwise the skipped pass is invisible.
            let reason: String
            switch error {
            case WPEMetalRenderExecutorError.shaderTranslatorUnavailable(_, let r): reason = r
            case WPEMetalRenderExecutorError.unsupportedShader: reason = "unsupported shader"
            default: reason = String(describing: error)
            }
            shaderErrorSink.record(shader: program.name, reason: reason)
            throw error
        }
    }
}
#endif
