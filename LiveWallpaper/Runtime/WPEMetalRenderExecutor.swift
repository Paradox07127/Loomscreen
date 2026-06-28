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

    /// WPE genericimage4 puppet clip-composite (clip-mask RT + CLIPPINGTARGET) so an eye
    /// puppet's pupil is occluded when the blink closes. Default OFF; only takes effect when
    /// the builder injected a clip-mask binding (texture slot 8) onto a genericimage4 pass.
    /// `defaults write Taijia.LiveWallpaper WPEPuppetClipComposite -bool YES`.
    static var puppetClipCompositeEnabled: Bool {
        puppetDefaultsFlag("WPEPuppetClipComposite")
    }

    /// Reads an opt-in bool from the app's `Taijia.LiveWallpaper` suite first, falling back to the
    /// process `.standard` domain. Puppet flags MUST share this so `defaults write Taijia.LiveWallpaper …`
    /// is honoured uniformly even when the renderer runs in a process whose standard domain isn't the app's.
    static func puppetDefaultsFlag(_ key: String) -> Bool {
        if let suite = UserDefaults(suiteName: "Taijia.LiveWallpaper"), suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Suite-first variant that distinguishes "unset" (`nil`) from an explicit value, for override flags.
    static func puppetDefaultsFlagOptional(_ key: String) -> Bool? {
        if let suite = UserDefaults(suiteName: "Taijia.LiveWallpaper"), suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return nil
    }

    static let refractionSnapshotReuseDefaultsKey = "WPEMetalRefractionSnapshotReuseEnabled"
    /// Skip the per-refract-pass full-frame blit while no write has touched the
    /// same output texture since the last snapshot. Default ON; suite-first so
    /// `defaults write Taijia.LiveWallpaper WPEMetalRefractionSnapshotReuseEnabled
    /// -bool NO` is honoured even when the renderer runs outside the app's standard domain.
    static var isRefractionSnapshotReuseEnabled: Bool {
        if let suite = UserDefaults(suiteName: "Taijia.LiveWallpaper"),
           suite.object(forKey: refractionSnapshotReuseDefaultsKey) != nil {
            return suite.bool(forKey: refractionSnapshotReuseDefaultsKey)
        }
        return UserDefaults.standard.object(forKey: refractionSnapshotReuseDefaultsKey) as? Bool ?? true
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

    static let staticLayerCacheDefaultsKey = "WPEMetalStaticLayerCacheEnabled"
    static let staticLayerCacheBudgetMiBDefaultsKey = "WPEMetalStaticLayerCacheBudgetMiB"

    /// Opt-in exact composite cache for static WPE layers. Default OFF so the
    /// existing render path stays byte-identical unless explicitly enabled
    /// (`defaults write … WPEMetalStaticLayerCacheEnabled -bool YES`).
    static var isStaticLayerCacheEnabled: Bool {
        UserDefaults.standard.object(forKey: staticLayerCacheDefaultsKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: staticLayerCacheDefaultsKey)
    }

    /// VRAM budget for cached composites (MiB; default 256). Over budget → LRU
    /// eviction, and the evicted layer falls back to re-rendering (slower, never wrong).
    static var staticLayerCacheBudgetBytes: Int {
        let raw = UserDefaults.standard.object(forKey: staticLayerCacheBudgetMiBDefaultsKey)
        let mib = (raw as? NSNumber)?.intValue ?? 256
        return max(0, mib) * 1_048_576
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

    static let shaderPrewarmDefaultsKey = "WPEMetalShaderPrewarmEnabled"
    /// Off-thread shader-transpile pre-warm. Default ON (validated on-device: heavy
    /// scenes ~halved their load, e.g. 3226487183 3.3s→1.7s, with firstFrame-transpile
    /// collapsing 1.9s→~0.1s; output-invariant by construction). Manual override still
    /// wins: `defaults write … WPEMetalShaderPrewarmEnabled -bool NO`.
    static var isShaderPrewarmEnabled: Bool {
        UserDefaults.standard.object(forKey: shaderPrewarmDefaultsKey) as? Bool ?? true
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
    private var previousFrameHistory: PreviousFrameHistory?
    /// Clip-composite role detection depends on the object's animation layers, so cache the resolved
    /// (source→target) part pairs per `objectID` (empty array = clip puppet with no eligible pair).
    private var puppetClipPairsCache: [String: [PuppetClipPair]] = [:]
    /// Throttles the one-shot clip-activation diagnostic to once per objectID.
    private var loggedClipActivation: Set<String> = []
    private var msdfTextPipelineCache: [MSDFTextPipelineKey: MTLRenderPipelineState] = [:]
    private var msdfNeutralWhiteTexture: MTLTexture?
    private lazy var staticLayerCompositeCache = WPEMetalStaticLayerCompositeCache(
        budgetBytes: WPEMetalRenderExecutor.staticLayerCacheBudgetBytes
    )
    private var staticLayerCacheSceneSize: CGSize?
    private var loggedStaticLayerCacheHits: Set<String> = []

    /// Scene-output ring: per-frame outputs are recycled instead of freshly
    /// allocated every `render()` (~32 MB alloc/free per frame at 4K). A slot
    /// is reused only when (a) no async present of it is still in flight and
    /// (b) it is not among the most recently vended outputs (`maxFramesInFlight`,
    /// min 2) — the renderer re-presents the latest output for static scenes,
    /// `previousFrameHistory` may still read the prior one, and under async
    /// submission an in-flight render may still be writing it.
    private var outputTexturePool: [MTLTexture] = []
    /// The most recently vended output textures (newest last); retained count is
    /// `max(2, maxFramesInFlight)` — see `noteVendedOutputTexture`.
    private var recentOutputTextureIDs: [ObjectIdentifier] = []
    private let presentTracker = PresentInFlightTracker()
    /// Diagnostics that hold several successive frame textures at once
    /// (`debugRenderSuccessiveFrameTextures`) disable recycling so each frame
    /// keeps distinct storage.
    var isOutputPoolingEnabled = true

    /// Max frames whose command buffers may be in flight at once when submitting
    /// asynchronously. MUST equal the `recentOutputTextureIDs` retention: a vended
    /// output target stays out of the reuse set for exactly that many subsequent
    /// vends, and the semaphore guarantees its render has completed by the time it
    /// falls out — so a target is never recycled while its GPU write is in flight.
    /// (See `isOutputTextureReusable` / `noteVendedOutputTexture`.)
    static let maxFramesInFlight = 2
    /// Backpressure for asynchronous frame submission: blocks the render caller
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
    private var bootstrapPreviousTextureCache: [BootstrapPreviousKey: MTLTexture] = [:]

    private struct BootstrapPreviousKey: Hashable {
        let targetID: WPEMetalTargetID
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }

    /// Present completion handlers run on Metal's callback threads while the
    /// pool is consulted from the render thread, so the in-flight refcounts
    /// live behind a lock in a Sendable box the handler can capture.
    private final class PresentInFlightTracker: @unchecked Sendable {
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
        invalidateStaticLayerCache()
        // Clip-role detection + activation diagnostics are keyed by objectID, which a reload can reuse
        // for a different puppet/material/animation, so drop them when the graph is rebuilt.
        puppetClipPairsCache.removeAll()
        loggedClipActivation.removeAll()
        // Scene size / pipeline may change across a reload; drop the recycled
        // frame targets so the next render() re-allocates at the right size.
        outputTexturePool.removeAll()
        recentOutputTextureIDs.removeAll()
        bootstrapPreviousTextureCache.removeAll()
    }

    /// Drops every cached static-layer composite. Called on scene reload /
    /// pipeline rebuild / sceneSize change so a new scene never reads stale pixels.
    func invalidateStaticLayerCache() {
        staticLayerCompositeCache.removeAll()
        staticLayerCacheSceneSize = nil
        loggedStaticLayerCacheHits.removeAll(keepingCapacity: false)
    }

    // MARK: - FBO memory diagnostic (read-only)

    private struct FBOMemoryLifetime {
        var firstPassIndex: Int
        var lastPassIndex: Int

        mutating func touch(_ passIndex: Int) {
            firstPassIndex = min(firstPassIndex, passIndex)
            lastPassIndex = max(lastPassIndex, passIndex)
        }
    }

    /// Logs a static account of the scene's render-target (FBO) memory when
    /// `WPEMetalFBOMemoryReport` is set — total (sum) vs estimated peak-concurrent
    /// (the aliasing headroom), per-target bytes + lifetime, and ping-pong
    /// secondaries. Read-only: computes keys WITHOUT allocating, mutates nothing.
    func logFBOMemoryReportIfRequested(
        pipeline: WPEPreparedRenderPipeline,
        sceneSize: CGSize,
        sceneID: String?
    ) {
        guard UserDefaults.standard.bool(forKey: "WPEMetalFBOMemoryReport") else { return }
        Logger.notice(
            fboMemoryReport(pipeline: pipeline, sceneSize: sceneSize, sceneID: sceneID),
            category: .performance
        )
    }

    private func fboMemoryReport(
        pipeline: WPEPreparedRenderPipeline,
        sceneSize: CGSize,
        sceneID: String?
    ) -> String {
        let declaredFBOs = Self.fboReportDeclaredFBOs(in: pipeline)
        var flattened: [(index: Int, layer: WPEPreparedRenderLayer, pass: WPEPreparedRenderPass)] = []
        var passIndex = 0
        for layer in pipeline.layers {
            for pass in layer.passes {
                flattened.append((passIndex, layer, pass))
                passIndex += 1
            }
        }

        // Only `.fbo` / `.layerComposite` allocate through the targetPool;
        // `.scene` resolves to the output texture (separate output pool), so it
        // is NOT an FBO-pool allocation and must be excluded from this account.
        func poolKey(for target: WPERenderTarget, layer: WPEPreparedRenderLayer) -> WPEMetalRenderTargetKey? {
            switch target {
            case .scene:
                return nil
            case .fbo, .layerComposite:
                return targetPool.diagnosticKey(
                    for: target,
                    layer: layer.graphLayer,
                    sceneSize: sceneSize,
                    declaredFBOs: declaredFBOs
                )
            }
        }

        var bytesByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var keysByName: [String: Set<WPEMetalRenderTargetKey>] = [:]
        for item in flattened {
            guard let targetKey = poolKey(for: item.pass.pass.target, layer: item.layer) else { continue }
            bytesByKey[targetKey] = Self.fboReportBytes(for: targetKey)
            keysByName[targetKey.name, default: []].insert(targetKey)
        }

        var lifetimes: [WPEMetalRenderTargetKey: FBOMemoryLifetime] = [:]
        var secondaryKeys = Set<WPEMetalRenderTargetKey>()
        var writtenTargets = Set<WPEMetalTargetID>()

        func touch(_ key: WPEMetalRenderTargetKey, at index: Int) {
            if lifetimes[key] != nil {
                lifetimes[key]?.touch(index)
            } else {
                lifetimes[key] = FBOMemoryLifetime(firstPassIndex: index, lastPassIndex: index)
            }
        }

        for item in flattened {
            let targetID = WPEMetalTargetID(target: item.pass.pass.target)
            let targetKey = poolKey(for: item.pass.pass.target, layer: item.layer)
            if let targetKey {
                touch(targetKey, at: item.index)
                // A pool secondary (ping-pong) is only allocated when the target
                // was already written this frame — a first-write `.previous` reads
                // the cleared bootstrap, not a pool secondary.
                if writtenTargets.contains(targetID),
                   passReadsCurrentTarget(item.pass, targetID: targetID) {
                    secondaryKeys.insert(targetKey)
                }
            }
            // Lifetime uses the EFFECTIVE bindings (the builder rewrites bind
            // `.previous` → source), so a stale raw `.previous` doesn't extend the
            // wrong target's lifetime and inflate the peak estimate.
            for reference in fboReportEffectiveTextureReferences(for: item.pass) {
                switch reference {
                case .fbo(let name):
                    for namedKey in keysByName[name] ?? [] {
                        touch(namedKey, at: item.index)
                    }
                case .previous:
                    if let targetKey { touch(targetKey, at: item.index) }
                case .image, .asset:
                    break
                }
            }
            writtenTargets.insert(targetID)
        }

        let uniqueKeys = bytesByKey.keys.sorted(by: Self.fboReportSort)
        let sumBytes = uniqueKeys.reduce(0) { $0 + (bytesByKey[$1] ?? 0) }
        let secondaryBytes = secondaryKeys.reduce(0) { $0 + (bytesByKey[$1] ?? 0) }
        let peakBytes = Self.fboReportPeakBytes(lifetimes: lifetimes, bytesByKey: bytesByKey)
        let aliased = Self.fboReportSameSizeAliased(lifetimes: lifetimes, bytesByKey: bytesByKey)
        let aliasHeapBytes = Self.fboReportAliasHeapBytes(lifetimes: lifetimes, bytesByKey: bytesByKey)
        let totalBytes = sumBytes + secondaryBytes
        let sceneLabel = sceneID ?? "-"

        var lines = [
            "[fbo-report] scene=\(sceneLabel) size=\(Int(sceneSize.width))x\(Int(sceneSize.height)) "
                + "count=\(uniqueKeys.count) sum=\(Self.fboReportMiB(sumBytes))MiB "
                + "secondary=\(Self.fboReportMiB(secondaryBytes))MiB(\(secondaryKeys.count)) "
                + "total=\(Self.fboReportMiB(totalBytes))MiB "
                + "peakFloor=\(Self.fboReportMiB(peakBytes))MiB "
                + "aliasSameSize=\(Self.fboReportMiB(aliased.bytes))MiB(save\(Self.fboReportMiB(sumBytes - aliased.bytes))MiB) "
                + "aliasHeap=\(Self.fboReportMiB(aliasHeapBytes))MiB(save\(Self.fboReportMiB(sumBytes - aliasHeapBytes))MiB)"
        ]
        for key in uniqueKeys {
            let bytes = bytesByKey[key] ?? 0
            let range = lifetimes[key].map { "\($0.firstPassIndex)..\($0.lastPassIndex)" } ?? "-"
            let secondary = secondaryKeys.contains(key) ? " secondary" : ""
            lines.append(
                "[fbo-report]   \(key.name) \(key.width)x\(key.height) \(key.format) "
                    + "\(Self.fboReportMiB(bytes))MiB life=\(range)\(secondary)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func fboReportDeclaredFBOs(in pipeline: WPEPreparedRenderPipeline) -> [String: WPERenderFBO] {
        var declared: [String: WPERenderFBO] = [:]
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declared[fbo.name] = fbo
            }
        }
        return declared
    }

    /// Effective texture reads — `pass.source` plus the rewritten bindings (the
    /// builder turns bind `.previous` into `pass.source`), used for accurate
    /// name-based lifetime/peak (unlike the raw hazard predicate).
    private func fboReportEffectiveTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        var references: [WPETextureReference] = [pass.pass.source]
        references.append(contentsOf: pass.textureBindings.values)
        return references
    }

    private static func fboReportBytes(for key: WPEMetalRenderTargetKey) -> Int {
        key.width * key.height * fboReportBytesPerPixel(for: key.pixelFormat)
    }

    private static func fboReportBytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba16Float:
            return 8
        case .r8Unorm:
            return 1
        default:
            return 4
        }
    }

    private static func fboReportPeakBytes(
        lifetimes: [WPEMetalRenderTargetKey: FBOMemoryLifetime],
        bytesByKey: [WPEMetalRenderTargetKey: Int]
    ) -> Int {
        guard let maxPass = lifetimes.values.map(\.lastPassIndex).max() else { return 0 }
        var peak = 0
        for index in 0...maxPass {
            let liveBytes = lifetimes.reduce(0) { partial, entry in
                guard entry.value.firstPassIndex <= index, index <= entry.value.lastPassIndex else {
                    return partial
                }
                return partial + (bytesByKey[entry.key] ?? 0)
            }
            peak = max(peak, liveBytes)
        }
        return peak
    }

    /// Realizable memory if same-(size,format) FBOs with non-overlapping
    /// lifetimes share one physical texture (greedy interval coloring per
    /// group) — the SAFE aliasing approach: same-MTLTexture reuse within the
    /// frame, `.tracked` heaps barrier the transitions, no makeAliasable/offset
    /// math. Less than the placement-heap `peakFloor` (which packs mixed sizes).
    private static func fboReportSameSizeAliased(
        lifetimes: [WPEMetalRenderTargetKey: FBOMemoryLifetime],
        bytesByKey: [WPEMetalRenderTargetKey: Int]
    ) -> (bytes: Int, slots: Int) {
        struct Group: Hashable {
            let width: Int
            let height: Int
            let pixelFormat: UInt
        }
        var intervalsByGroup: [Group: [(first: Int, last: Int)]] = [:]
        var bytesByGroup: [Group: Int] = [:]
        for (key, lifetime) in lifetimes {
            let group = Group(width: key.width, height: key.height, pixelFormat: key.pixelFormat.rawValue)
            intervalsByGroup[group, default: []].append((lifetime.firstPassIndex, lifetime.lastPassIndex))
            bytesByGroup[group] = bytesByKey[key] ?? 0
        }
        var totalBytes = 0
        var totalSlots = 0
        for (group, intervals) in intervalsByGroup {
            // Greedy interval coloring: reuse a slot only when its occupant's
            // last use ended STRICTLY before this FBO's first use (no same-pass
            // read/write of a shared texture).
            var slotEnds: [Int] = []
            for interval in intervals.sorted(by: { $0.first < $1.first }) {
                if let slot = slotEnds.firstIndex(where: { $0 < interval.first }) {
                    slotEnds[slot] = interval.last
                } else {
                    slotEnds.append(interval.last)
                }
            }
            totalSlots += slotEnds.count
            totalBytes += slotEnds.count * (bytesByGroup[group] ?? 0)
        }
        return (totalBytes, totalSlots)
    }

    /// Realizable memory with full placement-heap aliasing (mixed sizes packed
    /// by `WPEMetalFBOAliasPlanner`) — the consistent big win, ≈ peakFloor. This
    /// is the size the Phase-B shared heap will actually allocate.
    private static func fboReportAliasHeapBytes(
        lifetimes: [WPEMetalRenderTargetKey: FBOMemoryLifetime],
        bytesByKey: [WPEMetalRenderTargetKey: Int]
    ) -> Int {
        var intervals: [WPEMetalFBOAliasPlanner.Interval] = []
        for (index, key) in lifetimes.keys.enumerated() {
            guard let lifetime = lifetimes[key], let size = bytesByKey[key] else { continue }
            intervals.append(.init(id: index, size: size, firstPass: lifetime.firstPassIndex, lastPass: lifetime.lastPassIndex))
        }
        return WPEMetalFBOAliasPlanner.plan(intervals).heapSize
    }

    /// Conservative alias intervals handed to the target pool: per pool-FBO key,
    /// its `[firstPass, lastPass]` over the flattened render order. Reads use the
    /// UNION (`textureReferences`) so a target's last use is never under-counted
    /// — the pool may only make it aliasable AFTER this index, never before
    /// (which would corrupt the frame). Ping-pong secondaries are excluded (they
    /// need two simultaneous textures and stay on the discrete path).
    private func fboAliasIntervals(
        pipeline: WPEPreparedRenderPipeline,
        sceneSize: CGSize
    ) -> [WPEMetalRenderTargetPool.AliasInterval] {
        let declaredFBOs = Self.fboReportDeclaredFBOs(in: pipeline)
        var flattened: [(index: Int, layer: WPEPreparedRenderLayer, pass: WPEPreparedRenderPass)] = []
        var passIndex = 0
        for layer in pipeline.layers {
            for pass in layer.passes {
                flattened.append((passIndex, layer, pass))
                passIndex += 1
            }
        }

        func poolKey(for target: WPERenderTarget, layer: WPEPreparedRenderLayer) -> WPEMetalRenderTargetKey? {
            switch target {
            case .scene:
                return nil
            case .fbo, .layerComposite:
                return targetPool.diagnosticKey(for: target, layer: layer.graphLayer, sceneSize: sceneSize, declaredFBOs: declaredFBOs)
            }
        }

        var keysByName: [String: Set<WPEMetalRenderTargetKey>] = [:]
        for item in flattened {
            if let key = poolKey(for: item.pass.pass.target, layer: item.layer) {
                keysByName[key.name, default: []].insert(key)
            }
        }

        var firstPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var lastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var secondaryKeys = Set<WPEMetalRenderTargetKey>()
        var writtenTargets = Set<WPEMetalTargetID>()

        func touch(_ key: WPEMetalRenderTargetKey, _ index: Int) {
            if firstPassByKey[key] == nil { firstPassByKey[key] = index }
            lastPassByKey[key] = max(lastPassByKey[key] ?? index, index)
        }

        for item in flattened {
            let targetID = WPEMetalTargetID(target: item.pass.pass.target)
            let targetKey = poolKey(for: item.pass.pass.target, layer: item.layer)
            if let targetKey {
                touch(targetKey, item.index)
                if writtenTargets.contains(targetID),
                   passReadsCurrentTarget(item.pass, targetID: targetID) {
                    secondaryKeys.insert(targetKey)
                }
            }
            for reference in textureReferences(for: item.pass) {
                switch reference {
                case .fbo(let name):
                    for namedKey in keysByName[name] ?? [] { touch(namedKey, item.index) }
                case .previous:
                    if let targetKey { touch(targetKey, item.index) }
                case .image, .asset:
                    break
                }
            }
            writtenTargets.insert(targetID)
        }

        return firstPassByKey.compactMap { key, first in
            guard !secondaryKeys.contains(key), let last = lastPassByKey[key] else { return nil }
            return WPEMetalRenderTargetPool.AliasInterval(key: key, firstPass: first, lastPass: last)
        }
    }

    private static func fboReportSort(_ lhs: WPEMetalRenderTargetKey, _ rhs: WPEMetalRenderTargetKey) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        if lhs.format != rhs.format { return lhs.format < rhs.format }
        return lhs.pixelFormat.rawValue < rhs.pixelFormat.rawValue
    }

    private static func fboReportMiB(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576.0)
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
        if asyncSubmission { inFlightSemaphore.wait() }
        var didCommitAsync = false
        defer { if asyncSubmission && !didCommitAsync { inFlightSemaphore.signal() } }
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
        let staticLayerCacheEnabled = Self.isStaticLayerCacheEnabled && !Self.bypassEffectsForDebug
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
        let aliasIntervals = (WPEMetalRenderTargetPool.isFBOAliasingEnabled && !Self.bypassEffectsForDebug)
            ? fboAliasIntervals(pipeline: preparedPipeline, sceneSize: size)
            : []
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
            previousSceneTexture: reusableHistory?.sceneTexture,
            previousNamedTextures: reusableHistory?.namedTextures ?? [:]
        )
        frameState.cameraParallax = runtimeUniforms.cameraParallax
        currentSceneSize = size
        groupingContainerObjectIDs = Set(preparedPipeline.layers.compactMap { $0.graphLayer.parentObjectID })
        persistentDepthTargetIDs = computePersistentDepthTargetIDs(for: preparedPipeline)
        var didEncode = false
        let bypassEffects = Self.bypassEffectsForDebug
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
        func flushParticles(before threshold: Int) throws {
            while particleCursor < sortedParticles.count,
                  sortedParticles[particleCursor].sortIndex < threshold {
                let system = sortedParticles[particleCursor]
                let traceIndex = particleCursor
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
                    captureScenePassIfDumping(dumpScenePasses, label: "particle.\(system.sortIndex).\(traceIndex)", output: output, commandBuffer: commandBuffer)
                    #endif
                }
                particleCursor += 1
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
                    dynamicTextureNames: dynamicTextureNames
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
                    Logger.info(
                        "[WPE.bypass] skipped layer \(layer.graphLayer.objectID): source \(firstSource) not blittable (\(error))",
                        category: .wpeRender
                    )
                }
                didEncode = true
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
                if case .scene = pass.pass.target {
                    captureScenePassIfDumping(dumpScenePasses, label: pass.pass.id, output: output, commandBuffer: commandBuffer)
                }
                #endif
            }
        }

        try flushParticles(before: Int.max)

        guard didEncode else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }

        if asyncSubmission {
            // Bound in-flight depth (signal mirrors the wait above) and surface
            // GPU errors from the handler — they land after we've returned, so we
            // log rather than throw; the wallpaper just renders the next frame.
            // GPU-side ordering on the shared queue still guarantees the text and
            // present buffers (committed later) observe this frame's writes.
            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { cb in
                semaphore.signal()
                // Logged in every build (the old synchronous path threw on error,
                // which the caller logged) so a GPU failure isn't silent in release.
                if cb.status == .error {
                    Logger.warning(
                        "[WPE async-frame] command buffer error: \(cb.error?.localizedDescription ?? "unknown")",
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

    /// Snapshots every composite whose last producer is `passIndex` into a
    /// persistent texture, redirects `frameState` so this frame already reads the
    /// snapshot (identical pixels), and — once all of the plan's targets are
    /// captured — commits them to the cache as one layer entry. If the layer's
    /// total exceeds the budget, the partial snapshots are discarded and the
    /// layer keeps re-rendering (slower, never wrong).
    private func captureStaticLayerSnapshots(
        at passIndex: Int,
        plan: WPEMetalStaticLayerCachePlan,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState,
        snapshots: inout [String: MTLTexture],
        bytes: inout Int
    ) {
        for (targetName, producerIndex) in plan.cachedTargets where producerIndex == passIndex {
            guard snapshots[targetName] == nil,
                  let source = frameState.latestNamedTextures[targetName] else { continue }
            do {
                let cached = try targetPool.persistentTexture(
                    matching: source,
                    label: "WPE static layer cache \(layer.objectID) \(targetName)"
                )
                try copyTexture(source, to: cached, commandBuffer: commandBuffer)
                frameState.seedPreviousTexture(cached, targetID: .named(targetName))
                frameState.markInitialized(cached)
                snapshots[targetName] = cached
                bytes += Self.staticLayerCacheBytes(for: source)
            } catch {
                Logger.warning(
                    "[WPE.static-layer-cache] snapshot failed layer=\(layer.objectID) target=\(targetName): \(error)",
                    category: .wpeRender
                )
            }
        }

        // Commit only once every planned target is captured this frame.
        guard snapshots.count == plan.cachedTargets.count else { return }
        guard staticLayerCompositeCache.canAdmit(bytes: bytes) else {
            Logger.info(
                "[WPE.static-layer-cache] skip cache layer=\(layer.objectID) bytes=\(bytes) over budget",
                category: .wpeRender
            )
            return
        }
        let evicted = staticLayerCompositeCache.insert(
            layerID: layer.objectID,
            texturesByTarget: snapshots,
            bytes: bytes
        )
        Logger.info(
            "[WPE.static-layer-cache] cached layer=\(layer.objectID) targets=\(snapshots.count) passes=\(plan.compositePassCount) bytes=\(bytes)",
            category: .wpeRender
        )
        for layerID in evicted where layerID != layer.objectID {
            loggedStaticLayerCacheHits.remove(layerID)
            Logger.info("[WPE.static-layer-cache] evicted layer=\(layerID)", category: .wpeRender)
        }
    }

    private static func staticLayerCacheBytes(for texture: MTLTexture) -> Int {
        texture.width * texture.height * staticLayerCacheBytesPerPixel(for: texture.pixelFormat)
    }

    private static func staticLayerCacheBytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba16Float: return 8
        case .r8Unorm: return 1
        default: return 4
        }
    }

    /// Encode one particle system on top of `output`, in its own render pass
    /// (loadAction `.load`), into the SHARED scene command buffer — so particles
    /// interleave with layers at their scene paint index. Returns false (no
    /// encode) when the system has no live particles or its texture is missing.
    @discardableResult
    private func encodeParticleSystem(
        _ system: WPEParticleSystem,
        into commandBuffer: MTLCommandBuffer,
        output: MTLTexture,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame,
        texturesByMaterial: [ObjectIdentifier: MTLTexture],
        normalsByMaterial: [ObjectIdentifier: MTLTexture],
        frameState: inout WPEMetalFrameState,
        traceIndex: Int
    ) throws -> Bool {
        guard system.liveInstanceCount > 0 else { return false }
        // A rope needs ≥2 knots (4 verts) for a strip; a degenerate/empty ribbon
        // draws nothing, so skip the pass entirely rather than encode an empty one.
        if system.isRope, system.ropeVertexCount < 4 { return false }
        // Systems whose texture failed to load were filtered at scene-load; skip
        // defensively so a stale texture-slot binding can't leak in.
        guard let texture = texturesByMaterial[ObjectIdentifier(system)] else { return false }
        // REFRACT: needs the normal map AND a snapshot of the scene drawn so far
        // (= `_rt_FullFrameBuffer`) to sample as the refracted background. Without
        // either, fall back to the flat-sprite path.
        let refractNormal = system.isRope ? nil : normalsByMaterial[ObjectIdentifier(system)]
        let refractBackground: MTLTexture? = refractNormal == nil ? nil
            : snapshotForRefraction(of: output, into: commandBuffer, frameState: &frameState)
        let isRefract = refractNormal != nil && refractBackground != nil
        let state = try particlePipelineState(
            colorPixelFormat: output.pixelFormat,
            blendMode: system.blendMode,
            isRope: system.isRope,
            isRefract: isRefract
        )

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
        // Translate the whole system by its camera-parallax depth (pixels),
        // carried in `padding.xy` and added to each particle's screen position.
        let parallax = cameraParallax.pixelOffset(depth: system.parallaxDepth, sceneSize: sceneSize)
        projection.padding = SIMD4<Float>(parallax.x, parallax.y, 0, 0)

        let useFrameRects = system.frameRectsBuffer != nil
        var sprite = WPEParticleSpriteParams(
            grid: SIMD4<Float>(
                Float(system.spriteSheet?.cols ?? 1),
                Float(system.spriteSheet?.rows ?? 1),
                Float(system.spriteSheet?.frameCount ?? 1),
                (system.spriteSheet?.isAlphaMask ?? false) ? 1 : 0
            ),
            frameRectMode: SIMD4<Float>(
                useFrameRects ? 1 : 0,
                Float(system.spriteSheet?.frameRects?.count ?? 0),
                system.overbright,
                isRefract ? system.refractAmount : 0   // .w = g_RefractAmount (0 ⇒ non-refract)
            )
        )

        encoder.setRenderPipelineState(state)
        encoder.setVertexBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 2)
        encoder.setFragmentBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        if isRefract {
            // g_Texture1 = refraction normal map ; g_Texture3-equivalent = the
            // scene-so-far snapshot. sceneSize (projection) lets the fragment turn
            // its pixel position into a screen UV for the background sample.
            encoder.setFragmentTexture(refractNormal, index: 1)
            encoder.setFragmentTexture(refractBackground, index: 2)
            encoder.setFragmentBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 1)
        }
        if system.isRope, let ropeBuffer = system.ropeVertexBuffer {
            // One continuous ribbon strip: 2 edge vertices per knot, built by
            // `tick`. No instancing, no sprite-sheet rects.
            encoder.setVertexBuffer(ropeBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: system.ropeVertexCount
            )
        } else {
            encoder.setVertexBuffer(system.instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 3)
            // Buffer(4) must always be bound for the vertex function's signature.
            // Use the system's pre-allocated frame-rect buffer (any frame count);
            // a 1-element dummy covers the uniform-grid path.
            if let frameRectsBuffer = system.frameRectsBuffer {
                encoder.setVertexBuffer(frameRectsBuffer, offset: 0, index: 4)
            } else {
                var dummyFrameRect = SIMD4<Float>(0, 0, 1, 1)
                encoder.setVertexBytes(&dummyFrameRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
            }
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: system.liveInstanceCount
            )
        }
        encoder.endEncoding()
        // Mark the scene target written so a later scene pass loads (instead of
        // clearing away) the particles, previous-frame history + full-frame
        // aliases see them, and any refraction snapshot taken before this draw is
        // invalidated before the next interleaved pass requests another.
        frameState.registerWrite(texture: output, targetID: .scene)

        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordParticlePass(
            index: traceIndex,
            particleCount: system.liveInstanceCount,
            sprite: texture,
            blendMode: system.blendMode.rawValue,
            target: output,
            spriteSheet: system.spriteSheet.map {
                (cols: $0.cols, rows: $0.rows, frames: $0.frameCount, alphaMask: $0.isAlphaMask)
            }
        )
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "particle-state-\(traceIndex).txt",
                contents: system.particleStateDumpText())
        }
        #endif
        return true
    }

    /// Mirrors `WPEParticleSpriteParams` in `WPEMetalBuiltins.metal` —
    /// `grid.xy = (cols, rows)`, `grid.z = frameCount` (loop modulo),
    /// `grid.w = 1` flags an r8 alpha-mask atlas (fog particles) so the
    /// fragment shader pulls colour from the per-particle tint and uses
    /// the texture sample only as the opacity.
    ///
    /// `frameRectMode.x = 1` switches the vertex shader from uniform-grid
    /// slicing to explicit `frameRects` from buffer(4); `.y` is the rect count;
    /// `.z` is the material overbright colour multiplier (1 = unchanged).
    struct WPEParticleSpriteParams {
        var grid: SIMD4<Float>
        var frameRectMode: SIMD4<Float>
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
        // Same queue as the scene render, so this composites after it GPU-side
        // without a CPU stall; only block when a read-back needs finished pixels.
        if synchronizeFrameCompletion { commandBuffer.waitUntilCompleted() }
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
        // Same queue as the scene render, so this composites after it GPU-side
        // without a CPU stall; only block when a read-back needs finished pixels.
        if synchronizeFrameCompletion { commandBuffer.waitUntilCompleted() }
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
        let state = try WPEMetalCompileTimer.measure { try device.makeRenderPipelineState(descriptor: pipelineDescriptor) }
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
        let state = try WPEMetalCompileTimer.measure { try device.makeRenderPipelineState(descriptor: descriptor) }
        textOverlayPipelineCache[colorPixelFormat.rawValue] = state
        return state
    }

    private struct ParticlePipelineKey: Hashable {
        let pixelFormat: UInt
        let blendMode: WPEParticleBlendMode
        let isRope: Bool
        let isRefract: Bool
    }

    private var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]
    /// Reused scene snapshot storage for REFRACT particle passes; reallocated when
    /// the output size/format changes. A frame-local freshness guard decides
    /// whether the contents can be reused without another full-frame blit.
    private var refractionBackground: MTLTexture?

    /// Blit the scene-so-far into a private cached texture so a REFRACT particle
    /// pass can sample it as the refracted background (can't read+write the live
    /// attachment). Returns nil if the output can't be a blit source. Reuses the
    /// last snapshot when no write touched the same output texture since.
    private func snapshotForRefraction(
        of output: MTLTexture,
        into commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) -> MTLTexture? {
        guard !output.isFramebufferOnly else { return nil }
        let bg: MTLTexture
        if let cached = refractionBackground, cached.width == output.width,
           cached.height == output.height, cached.pixelFormat == output.pixelFormat {
            bg = cached
            if Self.isRefractionSnapshotReuseEnabled,
               frameState.hasFreshRefractionSnapshot(for: output) {
                return bg
            }
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: output.pixelFormat, width: output.width,
                height: output.height, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "WPE refraction background"
            refractionBackground = tex
            bg = tex
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: output, to: bg)
        blit.endEncoding()
        frameState.markRefractionSnapshotFresh(for: output)
        return bg
    }

    private func particlePipelineState(
        colorPixelFormat: MTLPixelFormat,
        blendMode: WPEParticleBlendMode,
        isRope: Bool = false,
        isRefract: Bool = false
    ) throws -> MTLRenderPipelineState {
        let key = ParticlePipelineKey(
            pixelFormat: colorPixelFormat.rawValue, blendMode: blendMode,
            isRope: isRope, isRefract: isRefract)
        if let cached = particlePipelineCache[key] {
            return cached
        }
        // Rope shares the instanced fragment (frameBlend 0 ⇒ one texture sample)
        // but uses a ribbon-strip vertex stage instead of the per-instance quad.
        // Refract reuses the instanced quad vertex but a fragment that multiplies
        // by the scene framebuffer at a normal-offset screen UV.
        let vertexName = isRope ? "wpe_particle_rope_vertex" : "wpe_particle_vertex"
        let fragmentName = isRefract ? "wpe_particle_refract_fragment" : "wpe_particle_instanced_fragment"
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
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
        let state = try WPEMetalCompileTimer.measure { try device.makeRenderPipelineState(descriptor: descriptor) }
        particlePipelineCache[key] = state
        return state
    }

    @MainActor
    func present(texture source: MTLTexture, in view: MTKView, fitMode: WPEPresentFitMode = .stretch) throws -> Bool {
        guard let drawable = view.currentDrawable else {
            #if DEBUG
            Logger.info(
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
            vertexName: "wpe_present_vertex",
            fragmentName: "wpe_present_fragment",
            blendMode: "disabled",
            colorPixelFormat: drawable.texture.pixelFormat
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(copyState)
        encoder.setFragmentTexture(source, index: 0)
        // Fit the scene texture's aspect to the drawable. Stretch reproduces the
        // legacy full-bleed; Fit/Fill preserve aspect (letterbox / crop) so
        // non-16:9 displays don't distort the scene.
        var presentUniforms = WPEPresentUniforms.make(
            fitMode: fitMode,
            sourceWidth: source.width,
            sourceHeight: source.height,
            targetWidth: drawable.texture.width,
            targetHeight: drawable.texture.height
        )
        encoder.setVertexBytes(&presentUniforms, length: MemoryLayout<WPEPresentUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        // The present buffer reads `source` asynchronously; refcount it so the
        // output ring doesn't hand the texture to the next frame's render
        // while this GPU read is still in flight.
        let sourceID = ObjectIdentifier(source)
        let tracker = presentTracker
        tracker.increment(sourceID)
        commandBuffer.addCompletedHandler { cb in
            tracker.decrement(sourceID)
            #if DEBUG
            if cb.status == .error {
                Logger.warning(
                    "[present] commandBuffer ERROR after present: \(cb.error?.localizedDescription ?? "unknown")",
                    category: .wpeRender
                )
            }
            #endif
        }
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

    /// Targets used by more than one depth pass (depth-write OR depth-test) — a
    /// later pass can `.load` an earlier pass's depth (e.g. `depthTest:less` across
    /// encoders), so their depth must stay persistent rather than transient/memoryless.
    private func computePersistentDepthTargetIDs(
        for pipeline: WPEPreparedRenderPipeline
    ) -> Set<WPEMetalTargetID> {
        var depthPassCounts: [WPEMetalTargetID: Int] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where depthCache.needsAttachment(for: pass) {
                depthPassCounts[WPEMetalTargetID(target: pass.pass.target), default: 0] += 1
            }
        }
        return Set(depthPassCounts.compactMap { $0.value > 1 ? $0.key : nil })
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

        if try encodePuppetClipCompositePassIfNeeded(
            pass: pass,
            layer: layer,
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
                descriptor.depthAttachment.loadAction = shouldLoadExistingAttachment ? .load : .clear
                descriptor.depthAttachment.storeAction = .store
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

    /// Composes each bone's WORLD bind matrix by walking the MDLS hierarchy (`world(parent) · rawLocal`),
    /// matching the palette's bind basis and the static attachment anchor (WPERenderGraphBuilder).
    /// Bones with a cycle / missing parent / unparseable matrix fall back to identity.
    private static func composedBindWorldByBoneIndex(_ bones: [WPEPuppetBone]) -> [Int: simd_float4x4] {
        let rawByIndex = Dictionary(
            bones.compactMap { bone -> (Int, simd_float4x4)? in
                WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix).map { (bone.index, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let parentByIndex = Dictionary(
            bones.map { ($0.index, $0.parentIndex) },
            uniquingKeysWith: { first, _ in first }
        )
        var cache: [Int: simd_float4x4] = [:]
        var visiting: Set<Int> = []
        func world(_ index: Int) -> simd_float4x4 {
            if let cached = cache[index] { return cached }
            guard let local = rawByIndex[index] else { return matrix_identity_float4x4 }
            guard !visiting.contains(index) else { return local }
            visiting.insert(index)
            let composed: simd_float4x4
            if let parent = parentByIndex[index] ?? nil {
                composed = world(parent) * local
            } else {
                composed = local
            }
            visiting.remove(index)
            cache[index] = composed
            return composed
        }
        var result: [Int: simd_float4x4] = [:]
        for bone in bones where rawByIndex[bone.index] != nil {
            result[bone.index] = world(bone.index)
        }
        return result
    }

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
        // Composed (parent-local hierarchy) bind world per bone — MUST match the palette's bind basis
        // (WPEPuppetAnimationEvaluator composes raw MDLS down the hierarchy). Using the raw matrices
        // here desyncs the attachment-follow anchor from `palette[bone] · bind⁻¹`, so a followed face/
        // hair layer drifts/stretches relative to the skinned head. See the palette fix (69ed52b).
        let boneBindByIndex = Self.composedBindWorldByBoneIndex(model.bones)
        func disabled(_ reason: String) -> PuppetSkinningState {
            PuppetSkinningState(
                enabled: false,
                palette: [],
                attachmentsByName: attachmentsByName,
                boneBindByIndex: boneBindByIndex,
                reason: reason
            )
        }

        // Bone skinning is opt-in (default OFF). Enabling it by default (9c44bab) together with the
        // relaxed displacement gate (e204842: 0.12→1.5·extent) regressed previously-static face/blink
        // puppets: their additive eye animation now passed the gate and got bone-skinned into
        // deformation (scenes 3461168300 / 3554161528). Skin only when the user explicitly opts in via
        // `defaults write Taijia.LiveWallpaper WPEPuppetEnableSkinning -bool YES`, until per-scene
        // skinning correctness is validated. Resolve from the SAME domain as `WPEPuppetClipComposite`
        // (Taijia suite first, .standard fallback) so the documented `defaults write Taijia.LiveWallpaper`
        // is honoured even when the renderer's standard domain isn't the app's — otherwise the clip flag
        // turns on but skinning silently stays off and the eye never deforms.
        guard Self.puppetDefaultsFlag("WPEPuppetEnableSkinning") else {
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
        // This bound only needs to catch a grossly exploding palette: structural failures
        // (non-finite, out-of-range skin indices, unresolved attachments, broken hierarchy) are
        // caught by the other gate conditions. The previous 0.12×extent was far too tight — it
        // rejected legit flowing-hair / gesture motion (e.g. Plana's finite 0.37×-extent swing),
        // leaving the whole puppet static (no blink/sway). A legit pose keeps every skinned vertex
        // within ~1.5 model extents of rest; beyond that the palette is exploding.
        let maxAllowedDelta = max(Float(256), extent * 1.5)
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
            parallaxDepth: layer.parallaxDepth,
            sortIndex: layer.sortIndex
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
        if shouldDeferPuppetMeshWarp(for: layer, model: model) {
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
        #if !LITE_BUILD && DEBUG
        let maskBindingReference: WPETextureReference?
        let maskBindingTexture: MTLTexture?
        let maskBindingName: String?
        let maskFallbackToPrimary: Bool
        #endif
        if normalizedShader == "genericimage4" {
            // A clip-composite binding (slot 8) is consumed by the dedicated clip pass; the
            // injected slot-1 mask must NOT be applied as a flat static mask to every part here.
            let maskRef = hasPuppetClipCompositeBinding(pass, layer: layer)
                ? nil
                : (pass.textureBindings[1] ?? pass.pass.textures[1])
            if let maskRef {
                let mask = try WPEMetalShaderInputs.resolve(
                    reference: maskRef,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                encoder.setFragmentTexture(mask, index: 1)
                hasMask = true
                #if !LITE_BUILD && DEBUG
                maskBindingReference = maskRef
                maskBindingTexture = mask
                maskBindingName = "g_Texture1"
                maskFallbackToPrimary = false
                #endif
            } else {
                encoder.setFragmentTexture(primary, index: 1)
                hasMask = false
                #if !LITE_BUILD && DEBUG
                maskBindingReference = nil
                maskBindingTexture = primary
                // hasMask == false: texture1 is bound only to satisfy the Metal
                // signature; the fragment never samples it, so leave it unnamed so
                // the oracle diff does not flag it as an asset divergence.
                maskBindingName = nil
                maskFallbackToPrimary = true
                #endif
            }
        } else {
            hasMask = false
            #if !LITE_BUILD && DEBUG
            maskBindingReference = nil
            maskBindingTexture = nil
            maskBindingName = nil
            maskFallbackToPrimary = false
            #endif
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

        #if !LITE_BUILD && DEBUG
        var canonicalTextureBindings = [
            WPECanonicalTraceRecorder.TextureBindingInput(
                slot: 0,
                name: "g_Texture0",
                reference: primaryRef,
                texture: primary,
                fallbackToPrimary: false
            )
        ]
        if let maskBindingTexture {
            canonicalTextureBindings.append(WPECanonicalTraceRecorder.TextureBindingInput(
                slot: 1,
                name: maskBindingName,
                reference: maskBindingReference,
                texture: maskBindingTexture,
                fallbackToPrimary: maskFallbackToPrimary
            ))
        }
        WPECanonicalTraceRecorder.shared.recordPuppetPass(
            pass: pass,
            stage: "material-mesh",
            layer: layer,
            modelPath: layer.puppetPath,
            meshes: meshes,
            destination: destination,
            textureBindings: canonicalTextureBindings,
            vertexShaderName: "wpe_puppet_mesh_vertex",
            fragmentShaderName: fragmentName,
            fragmentUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(name: "color", type: "vec4", value: uniforms.color),
                WPECanonicalTraceRecorder.PuppetUniformInput(name: "alphaMaskUV", type: "vec4", value: uniforms.alphaMaskUV)
            ],
            vertexUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "localSizeAndMode",
                    type: "vec4",
                    value: meshUniforms.localSizeAndMode
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "meshCenterAndPadding",
                    type: "vec4",
                    value: meshUniforms.meshCenterAndPadding
                )
            ],
            bonePalette: paletteState.bonePalette,
            skinningEnabled: paletteState.skinningEnabled != 0,
            localSize: SIMD2<Float>(meshUniforms.localSizeAndMode.x, meshUniforms.localSizeAndMode.y),
            meshCenter: SIMD2<Float>(meshUniforms.meshCenterAndPadding.x, meshUniforms.meshCenterAndPadding.y),
            objectCenterAndSize: nil
        )
        #endif

        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    /// Deferred-warp final composite (gated per-puppet by `shouldDeferPuppetMeshWarp`): the base +
    /// effect chain ran in puppet atlas/local UV space; here the skinned mesh warps that result into the
    /// scene, replacing the rectangular `copy`-to-`.scene` pass. Placement is copied 1:1 from
    /// `objectQuadUniforms` so a bind-pose, no-effect puppet stays byte-identical to the current path.
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
        guard case .scene = pass.pass.target,
              let model = puppetModel,
              // Mirrors the material-pass deferral decision (clip puppets already warped+clipped at
              // material time → false here → plain rectangular copy; no-effect puppets → false → the
              // material pass already warped directly). Only deferred puppets warp at the scene composite.
              shouldDeferPuppetMeshWarp(for: layer, model: model) else {
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
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordPuppetPass(
            pass: pass,
            stage: "scene-composite-mesh",
            layer: layer,
            modelPath: layer.puppetPath,
            meshes: meshes,
            destination: destination,
            textureBindings: [
                WPECanonicalTraceRecorder.TextureBindingInput(
                    slot: 0,
                    name: "g_Texture0",
                    reference: sourceReference,
                    texture: sourceTexture,
                    fallbackToPrimary: false
                )
            ],
            vertexShaderName: "wpe_puppet_scene_composite_vertex",
            fragmentShaderName: "wpe_copy_fragment",
            fragmentUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "uvOffsetAndPadding",
                    type: "vec4",
                    value: SIMD4<Float>(
                        copyUniforms.uvOffset.x,
                        copyUniforms.uvOffset.y,
                        copyUniforms.padding.x,
                        copyUniforms.padding.y
                    )
                )
            ],
            vertexUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "localSizeAndMode",
                    type: "vec4",
                    value: compositeUniforms.localSizeAndMode
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "meshCenterAndScaleSign",
                    type: "vec4",
                    value: compositeUniforms.meshCenterAndScaleSign
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "objectCenterAndSize",
                    type: "vec4",
                    value: compositeUniforms.objectCenterAndSize
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "sceneSizeAndRotation",
                    type: "vec4",
                    value: compositeUniforms.sceneSizeAndRotation
                )
            ],
            bonePalette: paletteState.bonePalette,
            skinningEnabled: paletteState.skinningEnabled != 0,
            localSize: localSize,
            meshCenter: SIMD2<Float>(
                compositeUniforms.meshCenterAndScaleSign.x,
                compositeUniforms.meshCenterAndScaleSign.y
            ),
            objectCenterAndSize: compositeUniforms.objectCenterAndSize
        )
        #endif
        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    private func puppetBonePalette(
        for skinningState: PuppetSkinningState?
    ) -> (bonePalette: [simd_float4x4], skinningEnabled: Float) {
        // When the skinning gate rejects (partial hierarchy, out-of-range indices, unbounded palette,
        // unfollowable attached child) the identity palette reproduces the assembled MDLV rest mesh
        // (no-regression guard). Skinning is opt-in (default off); enable with `defaults write
        // Taijia.LiveWallpaper WPEPuppetEnableSkinning -bool YES`.
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

    // MARK: - Puppet clip-composite (WPE genericimage4 CLIPPINGTARGET)

    /// Selects which puppet mesh parts a draw should emit.
    private enum PuppetPartSelection {
        case all
        case only(Set<UInt32>)

        var isAll: Bool {
            if case .all = self { return true }
            return false
        }

        func contains(_ part: WPEPuppetMeshPart) -> Bool {
            switch self {
            case .all: return true
            case .only(let ids): return ids.contains(part.id)
            }
        }
    }

    /// `alphaMaskUV.w` modes consumed by `wpe_genericimage4_puppet_clip_fragment`. Only `none`/`target`
    /// are emitted today (the shader also defines compose/both for future use).
    private enum PuppetClipFragmentMode {
        static let none: Float = 0
        static let target: Float = 1
    }

    /// One resolved clip relationship: `target` (e.g. a pupil that does not squish) is clipped to the
    /// silhouette of `source` (e.g. the eye-white that squishes shut), per WPE's first→second-part
    /// convention validated by squish geometry.
    private struct PuppetClipPair: Equatable {
        let source: UInt32
        let target: UInt32
    }

    private struct PuppetClipCompositePlan {
        /// Distinct clip-mask source part IDs, in mesh draw order. Each renders to its own clip RT.
        let sourcePartIDs: [UInt32]
        /// Maps a clip-target part ID to the source part whose silhouette clips it.
        let sourceForTarget: [UInt32: UInt32]
        let clipMaskReference: WPETextureReference
        let clipTargetName: String
    }

    /// True only when slot 8 is the EXACT builder-injected clip RT for this object — the same predicate
    /// `puppetUsesClipComposite` uses for defer routing, so the clip encoder and the deferred-warp
    /// decision can never disagree (an authored slot-8 FBO with another name is not a clip pass).
    private func hasPuppetClipCompositeBinding(_ pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> Bool {
        guard Self.puppetClipCompositeEnabled else { return false }
        let slot8 = pass.textureBindings[8] ?? pass.pass.textures[8]
        return slot8 == .fbo(Self.puppetClipRTName(objectID: layer.objectID))
    }

    /// Resolves the WPE clip-composite routing for a genericimage4 puppet the builder flagged with a clip
    /// mask (slot 1) + intermediate clip RT (slot 8). Part roles follow WPE's first→second-part
    /// convention (`detectClipPairs`): parts[0] is the clip silhouette, parts[1] is clipped to it, gated
    /// by squish geometry. A puppet whose convention/geometry doesn't hold yields nil → flat draw. The
    /// plan/encoder still model a list of source→target pairs so the data path generalises if WPE ever
    /// ships a multi-pair clip mesh, even though detection currently returns a single pair.
    private func puppetClipCompositePlan(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        model: WPEPuppetModel,
        renderableMeshes: [WPEPuppetMesh]
    ) -> PuppetClipCompositePlan? {
        guard Self.puppetClipCompositeEnabled,
              hasPuppetClipCompositeBinding(pass, layer: layer),
              WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) == "genericimage4",
              let clipMaskReference = pass.textureBindings[1] ?? pass.pass.textures[1],
              let clipTargetReference = pass.textureBindings[8] ?? pass.pass.textures[8],
              case .fbo(let clipTargetName) = clipTargetReference,
              renderableMeshes.count == 1,
              let mesh = renderableMeshes.first,
              mesh.parts.filter({ $0.count > 0 }).count >= 2 else {
            return nil
        }
        let pairs = resolvePuppetClipPairs(for: layer, model: model, mesh: mesh)
        guard !pairs.isEmpty else { return nil }

        // Preserve mesh draw order for the source RTs; dedupe shared sources (two targets, one source).
        var sourceIDs: [UInt32] = []
        var sourceForTarget: [UInt32: UInt32] = [:]
        for part in mesh.parts where part.count > 0 {
            for pair in pairs where pair.source == part.id && !sourceIDs.contains(part.id) {
                sourceIDs.append(part.id)
            }
        }
        for pair in pairs where sourceForTarget[pair.target] == nil {
            sourceForTarget[pair.target] = pair.source
        }
        guard !sourceIDs.isEmpty, !sourceForTarget.isEmpty else { return nil }

        return PuppetClipCompositePlan(
            sourcePartIDs: sourceIDs,
            sourceForTarget: sourceForTarget,
            clipMaskReference: clipMaskReference,
            clipTargetName: clipTargetName
        )
    }

    /// Per-puppet deferred-warp decision (replaces the old global flag). The deferred warp only matters
    /// for puppets with an effect chain — running base+effects in atlas/local UV space so effect masks
    /// align with the mesh, then warping at the scene composite. A no-effect puppet renders identically
    /// either way, so it stays on the direct (material-time warp) path and is byte-identical to the
    /// pre-deferral behaviour. Clip-composite puppets warp+clip at material time and never defer. A DEBUG
    /// `WPEPuppetDeferMeshWarp` override forces the decision for non-clip puppets (A/B testing).
    private func shouldDeferPuppetMeshWarp(for layer: WPERenderLayer, model: WPEPuppetModel) -> Bool {
        if puppetUsesClipComposite(layer: layer, model: model) { return false }
        // The deferred warp can only be applied if there's a `.scene` copy pass to land it on; without
        // one, deferring the material-time warp would lose it (the puppet would render unwarped). So even
        // a forced override stays on the direct path when no scene-warp target exists.
        guard layerHasDeferredWarpTarget(layer) else { return false }
        if let forced = Self.deferPuppetMeshWarpOverride { return forced }
        return layerHasEffectChain(layer)
    }

    /// The deferred warp is applied by `encodePuppetSceneCompositePassIfNeeded`, which only runs on a
    /// `.scene`-target `copy` pass. A layer without one cannot receive a deferred warp.
    private func layerHasDeferredWarpTarget(_ layer: WPERenderLayer) -> Bool {
        layer.passes.contains { pass in
            guard case .scene = pass.target else { return false }
            return WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.shader) == "copy"
        }
    }

    /// True when the puppet layer runs an effect — a material-kind effect (`.effect`) OR a command-kind
    /// effect (`.command(file:)`, e.g. blur/bloom passes). The synthesized final scene copy is also a
    /// `.command` pass but is the composite itself, not an effect, so it's excluded. Only puppets with an
    /// effect chain benefit from the deferred warp (effect masks align in atlas space).
    private func layerHasEffectChain(_ layer: WPERenderLayer) -> Bool {
        Self.hasEffectChain(passPhases: layer.passes.map(\.phase))
    }

    /// Pure predicate behind `layerHasEffectChain`, extracted for unit testing.
    static func hasEffectChain(passPhases: [WPERenderPassPhase]) -> Bool {
        passPhases.contains { phase in
            switch phase {
            case .effect: return true
            case .command(let file): return file != sceneCopyCommandFile
            case .material: return false
            }
        }
    }

    /// File of the builder's synthesized rectangular copy-to-`.scene` command (see
    /// `WPERenderLayer.finalizedPasses`); excluded from effect-chain detection.
    private static let sceneCopyCommandFile = "materials/util/copy.json"

    /// True when this puppet actually renders via the clip composite. Gated on the SAME conditions as
    /// `puppetClipCompositePlan`/`encodePuppetClipCompositePassIfNeeded` — clip flag on, a genericimage4
    /// material pass with the builder-injected clip RT (slot 8), and a geometry-confirmed first→second
    /// part pair — so the defer/clip routing can never disagree about whether the clip pass will run.
    private func puppetUsesClipComposite(layer: WPERenderLayer, model: WPEPuppetModel) -> Bool {
        guard Self.puppetClipCompositeEnabled, model.clipMaskName != nil else { return false }
        // Match the EXACT builder-injected clip RT (`WPERenderGraphBuilder` skips injection when slot 8
        // is already authored), not just any non-nil slot 8 — otherwise a pre-existing authored slot 8
        // would falsely suppress the deferred warp for a clip pass that won't actually run.
        let injectedClipRT = WPETextureReference.fbo(Self.puppetClipRTName(objectID: layer.objectID))
        let hasInjectedClipPass = layer.passes.contains { pass in
            guard case .material = pass.phase,
                  WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.shader) == "genericimage4" else {
                return false
            }
            return pass.textures[8] == injectedClipRT
        }
        guard hasInjectedClipPass else { return false }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard meshes.count == 1, let mesh = meshes.first else { return false }
        return !resolvePuppetClipPairs(for: layer, model: model, mesh: mesh).isEmpty
    }

    /// Canonical intermediate clip-mask RT name. MUST match `WPERenderGraphBuilder`'s injection
    /// (`_rt_puppetClip_<objectID>`) so defer routing and clip planning agree on the same pass.
    static func puppetClipRTName(objectID: String) -> String { "_rt_puppetClip_\(objectID)" }

    /// Cached clip-role detection. Keyed by `objectID` (not puppet path): detection depends on this
    /// object's animation layers, so two objects reusing the same puppet asset with different anims must
    /// not share a cache entry.
    private func resolvePuppetClipPairs(
        for layer: WPERenderLayer,
        model: WPEPuppetModel,
        mesh: WPEPuppetMesh
    ) -> [PuppetClipPair] {
        let cacheKey = layer.objectID
        if let cached = puppetClipPairsCache[cacheKey] {
            return cached
        }
        let animationLayers = puppetAnimationLayers(for: layer, model: model)
        let pairs = Self.detectClipPairs(mesh: mesh, animationLayers: animationLayers, bones: model.bones)
        puppetClipPairsCache[cacheKey] = pairs
        return pairs
    }

    /// Geometry signature of one mesh part under a given skinning palette: its 2D bounding box.
    private struct PuppetClipPartBox {
        let id: UInt32
        var minX: Float
        var maxX: Float
        var minY: Float
        var maxY: Float
        var width: Float { maxX - minX }
        var height: Float { maxY - minY }
        var centerX: Float { (minX + maxX) * 0.5 }
        var centerY: Float { (minY + maxY) * 0.5 }
    }

    /// Skins a single vertex with the palette exactly as `wpe_skin_puppet_position` does, so detection
    /// matches the rendered geometry. An empty palette returns the bind position.
    private static func skinPuppetVertex(_ vertex: WPEPuppetVertex, palette: [simd_float4x4]) -> SIMD3<Float> {
        let source = SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 1)
        guard !palette.isEmpty else { return vertex.position }
        let weights = SIMD4<Float>(
            max(vertex.skinBlendWeights.x, 0), max(vertex.skinBlendWeights.y, 0),
            max(vertex.skinBlendWeights.z, 0), max(vertex.skinBlendWeights.w, 0)
        )
        let weightSum = weights.x + weights.y + weights.z + weights.w
        guard weightSum > 1e-5 else { return vertex.position }
        let indices = [vertex.skinBlendIndices.x, vertex.skinBlendIndices.y,
                       vertex.skinBlendIndices.z, vertex.skinBlendIndices.w]
        let weightLanes = [weights.x, weights.y, weights.z, weights.w]
        var skinned = SIMD4<Float>(0, 0, 0, 0)
        for lane in 0..<4 where weightLanes[lane] > 0 {
            let bone = Int(indices[lane])
            let contribution = (bone >= 0 && bone < palette.count) ? palette[bone] * source : source
            skinned += weightLanes[lane] * contribution
        }
        skinned /= weightSum
        return SIMD3<Float>(skinned.x, skinned.y, skinned.z)
    }

    /// 2D bounding boxes for every non-empty part under `palette` (empty palette → bind pose).
    private static func clipPartBoxes(mesh: WPEPuppetMesh, palette: [simd_float4x4]) -> [PuppetClipPartBox] {
        var boxes: [PuppetClipPartBox] = []
        for part in mesh.parts where part.count > 0 {
            let start = max(part.start, 0)
            let end = min(part.start + part.count, mesh.indices.count)
            guard end > start else { continue }
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            var seen = false
            var visited = Set<UInt16>()
            for i in start..<end {
                let vertexIndex = mesh.indices[i]
                guard visited.insert(vertexIndex).inserted, Int(vertexIndex) < mesh.vertices.count else { continue }
                let p = skinPuppetVertex(mesh.vertices[Int(vertexIndex)], palette: palette)
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
                seen = true
            }
            guard seen else { continue }
            boxes.append(PuppetClipPartBox(id: part.id, minX: minX, maxX: maxX, minY: minY, maxY: maxY))
        }
        return boxes
    }

    /// Resolves the clip source→target pair for a clip-mask puppet. WPE's puppet clip is a fixed
    /// two-part convention (oracle-confirmed on 3719111841 via RenderDoc; the MDLV clip section and the
    /// material carry only the mask name, no per-part roles): the FIRST mesh part is the clip silhouette
    /// that squishes shut, the SECOND part is clipped to it and stays full. Animated geometry is used only
    /// to VALIDATE that shape (shape closes, target stays open inside it) so an unfamiliar rig degrades to
    /// a flat draw instead of being mis-clipped. Returns [] when the convention doesn't hold.
    private static func detectClipPairs(
        mesh: WPEPuppetMesh,
        animationLayers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone]
    ) -> [PuppetClipPair] {
        let bindBoxes = clipPartBoxes(mesh: mesh, palette: [])
        guard bindBoxes.count >= 2 else { return [] }
        var bindByID: [UInt32: PuppetClipPartBox] = [:]
        var minWidthByID: [UInt32: Float] = [:]
        var minHeightByID: [UInt32: Float] = [:]
        for box in bindBoxes where box.height > 1e-4 && box.width > 1e-4 {
            bindByID[box.id] = box
            minWidthByID[box.id] = box.width
            minHeightByID[box.id] = box.height
        }
        guard bindByID.count >= 2 else { return [] }

        guard let base = animationLayers.first(where: { !$0.additive }) ?? animationLayers.first else { return [] }
        let frameCount = max(base.animation.frameCount, 1)
        let fps = base.animation.fps > 0 ? Double(base.animation.fps) : 30
        // Sample evenly-spaced integer FRAME indices in [0, frameCount-1]. Sampling by time up to the
        // full `duration` would land the last sample on `frameCount/fps`, which a loop animation wraps
        // back to frame 0 — hiding a most-closed eye pose that only occurs on the final frame.
        let sampleCount = min(max(frameCount, 8), 48)
        for sample in 0..<sampleCount {
            let frame = frameCount <= 1 || sampleCount <= 1
                ? 0
                : Int((Double(sample) * Double(frameCount - 1) / Double(sampleCount - 1)).rounded())
            let palette = WPEPuppetAnimationEvaluator.palette(
                layers: animationLayers, bones: bones, at: Double(frame) / fps)
            guard !palette.isEmpty else { continue }
            for box in clipPartBoxes(mesh: mesh, palette: palette) {
                if let w = minWidthByID[box.id] { minWidthByID[box.id] = min(w, box.width) }
                if let h = minHeightByID[box.id] { minHeightByID[box.id] = min(h, box.height) }
            }
        }

        // Min-axis squish ratio over the clip: a part "squishes" when it collapses on EITHER axis
        // (anime eyes usually close vertically, but the test stays axis-agnostic).
        func ratio(_ id: UInt32) -> Float {
            guard let bind = bindByID[id], bind.width > 1e-4, bind.height > 1e-4 else { return 1 }
            let widthRatio = (minWidthByID[id] ?? bind.width) / bind.width
            let heightRatio = (minHeightByID[id] ?? bind.height) / bind.height
            return min(widthRatio, heightRatio)
        }
        let ratioSummary = bindByID.keys.sorted()
            .map { "id\($0)=\(String(format: "%.2f", ratio($0)))" }
            .joined(separator: " ")

        // WPE convention: parts[0] = clip silhouette, parts[1] = clipped target. Validate with geometry.
        let ordered = mesh.parts.filter { $0.count > 0 }
        guard ordered.count >= 2,
              let shape = bindByID[ordered[0].id],
              let target = bindByID[ordered[1].id] else {
            clipDiagnosticLog("[WPE clip] detect: NO PAIR (fewer than 2 measurable parts) minAxisRatios[\(ratioSummary)]")
            return []
        }
        let shapeRatio = ratio(shape.id)
        let targetRatio = ratio(target.id)
        let targetInsideShape = target.centerX >= shape.minX && target.centerX <= shape.maxX
            && target.centerY >= shape.minY && target.centerY <= shape.maxY
        guard shapeRatio < 0.85,              // the silhouette part actually closes
              targetRatio > 0.8,              // the clipped part stays open (would show through)
              targetRatio > shapeRatio + 0.1, // and is clearly fuller than the silhouette
              targetInsideShape else {        // and sits inside the silhouette
            clipDiagnosticLog(
                "[WPE clip] detect: NO PAIR (shape id\(shape.id)=\(String(format: "%.2f", shapeRatio)) "
                    + "target id\(target.id)=\(String(format: "%.2f", targetRatio)) inside=\(targetInsideShape)) "
                    + "minAxisRatios[\(ratioSummary)] — first part must close, second must stay open inside it; "
                    + "if all ~1.0 the mesh isn't deforming (skinning off?)"
            )
            return []
        }
        clipDiagnosticLog(
            "[WPE clip] detect: pair=\(shape.id)→\(target.id) "
                + "(shape=\(String(format: "%.2f", shapeRatio)) target=\(String(format: "%.2f", targetRatio))) "
                + "minAxisRatios[\(ratioSummary)]"
        )
        return [PuppetClipPair(source: shape.id, target: target.id)]
    }

    /// DEBUG-only `[WPE clip]` diagnostic sink (once-per-puppet/per-build messages); compiled out of
    /// Release so the clip path adds no log noise to shipped builds.
    private static func clipDiagnosticLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Gated behind the scene-debug switch (off by default) so genericimage4
        // puppet scenes don't print clip-detection lines on every load.
        guard UserDefaults.standard.bool(forKey: "WPESceneDebugArtifactsEnabled") else { return }
        Logger.info(message(), category: .wpeRender)
        #endif
    }

    #if DEBUG
    /// Test seam for the geometry-driven clip-role detection. Returns (source, target) part-ID pairs
    /// without surfacing the private `PuppetClipPair` type.
    static func _testDetectClipPairs(
        mesh: WPEPuppetMesh,
        animationLayers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone]
    ) -> [(source: UInt32, target: UInt32)] {
        detectClipPairs(mesh: mesh, animationLayers: animationLayers, bones: bones)
            .map { (source: $0.source, target: $0.target) }
    }
    #endif

    /// Encodes the clip composite in place of the flat puppet draw: render each clip-source silhouette to
    /// its own clip-mask RT, then draw all parts in mesh order to the main target (clip targets multiply
    /// alpha by their source silhouette, the rest draw plain). Returns false when the pass is not a
    /// clip-composite puppet so the caller falls through to the legacy path.
    private func encodePuppetClipCompositePassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        shouldLoadDestination: Bool,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws -> Bool {
        // The clip composite draws the warped mesh per-part at material time, so it runs even when
        // WPEPuppetDeferMeshWarp is globally on: a clip puppet bypasses the deferral locally (the
        // deferred scene-composite re-warp is suppressed for it in encodePuppetSceneCompositePassIfNeeded),
        // so deferred warp can stay on for non-clip puppets (e.g. 3461168300's head effect) without
        // breaking clip eyes (e.g. 3719111841).
        guard case .material = pass.pass.phase,
              case .layerComposite = pass.pass.target,
              let model = puppetModel else {
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard let plan = puppetClipCompositePlan(for: pass, layer: layer, model: model, renderableMeshes: meshes) else {
            return false
        }

        let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let clipMask = try WPEMetalShaderInputs.resolve(
            reference: plan.clipMaskReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )

        let paletteState = puppetBonePalette(for: skinningState)
        if loggedClipActivation.insert(layer.objectID).inserted {
            Self.clipDiagnosticLog(
                "[WPE clip] ACTIVE \(layer.puppetPath ?? layer.objectID): "
                    + "skinning=\(paletteState.skinningEnabled > 0.5 ? "ON" : "OFF") "
                    + "sources=\(plan.sourcePartIDs) targets=\(Array(plan.sourceForTarget.keys).sorted()) "
                    + "— if skinning=OFF the eye renders static (no squish), so nothing is clipped"
            )
        }
        // localSizeAndMode is taken from the MAIN destination for ALL draws so the clip mask
        // (rendered to a different-resolution RT) maps to the same NDC and the screen-space UV aligns.
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

        let transparentClear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // 1) Render each clip-source silhouette to its own intermediate clip-mask RT
        //    (clippingmaskimage4). The first source reuses the builder-registered RT (scale 2); any
        //    additional sources (e.g. a second eye) get derived RT names from the same base.
        var clipRTBySource: [UInt32: (id: WPEMetalTargetID, texture: MTLTexture)] = [:]
        for (index, sourceID) in plan.sourcePartIDs.enumerated() {
            let rtName = index == 0 ? plan.clipTargetName : "\(plan.clipTargetName)_s\(index)"
            let clipRT = try targetTexture(for: .fbo(name: rtName), layer: layer, frameState: &frameState)
            try encodePuppetClipCompositeDraw(
                pass: pass, layer: layer, meshes: meshes,
                partSelection: .only([sourceID]),
                destination: clipRT, loadAction: .clear, clearColor: transparentClear,
                primary: primary, mask: clipMask, clipTexture: nil,
                vertexName: "wpe_puppet_mesh_clip_vertex", fragmentName: "wpe_puppet_clippingmaskimage4_fragment",
                blendMode: "disabled", hasMask: true, clipMode: PuppetClipFragmentMode.none,
                meshUniforms: &meshUniforms, paletteState: paletteState, commandBuffer: commandBuffer
            )
            frameState.registerWrite(texture: clipRT.texture, targetID: clipRT.id)
            clipRTBySource[sourceID] = clipRT
        }

        // 2) Draw all parts to the main target in mesh draw order. A clip-target part multiplies its
        //    alpha by its source silhouette (screen-space CLIPPINGTARGET); every other part draws plain.
        //    Consecutive plain parts batch into one draw, preserving translucent ordering.
        var didClearMain = false
        func mainLoadAction() -> MTLLoadAction {
            defer { didClearMain = true }
            return (didClearMain || shouldLoadDestination) ? .load : .clear
        }
        var plainRun: [UInt32] = []
        func flushPlainRun() throws {
            guard !plainRun.isEmpty else { return }
            let selection = plainRun
            plainRun.removeAll(keepingCapacity: true)
            try encodePuppetClipCompositeDraw(
                pass: pass, layer: layer, meshes: meshes,
                partSelection: .only(Set(selection)),
                destination: destination, loadAction: mainLoadAction(),
                clearColor: clearColor(for: destination.id),
                primary: primary, mask: primary, clipTexture: nil,
                vertexName: "wpe_puppet_mesh_vertex", fragmentName: "wpe_genericimage4_fragment",
                blendMode: pass.pass.blending, hasMask: false, clipMode: PuppetClipFragmentMode.none,
                meshUniforms: &meshUniforms, paletteState: paletteState, commandBuffer: commandBuffer
            )
        }

        for part in meshes.first?.parts ?? [] where part.count > 0 {
            guard let sourceID = plan.sourceForTarget[part.id],
                  let clipRT = clipRTBySource[sourceID] else {
                plainRun.append(part.id)
                continue
            }
            try flushPlainRun()
            try encodePuppetClipCompositeDraw(
                pass: pass, layer: layer, meshes: meshes,
                partSelection: .only([part.id]),
                destination: destination, loadAction: mainLoadAction(),
                clearColor: clearColor(for: destination.id),
                primary: primary, mask: primary, clipTexture: clipRT.texture,
                vertexName: "wpe_puppet_mesh_clip_vertex", fragmentName: "wpe_genericimage4_puppet_clip_fragment",
                blendMode: pass.pass.blending, hasMask: false, clipMode: PuppetClipFragmentMode.target,
                meshUniforms: &meshUniforms, paletteState: paletteState, commandBuffer: commandBuffer
            )
        }
        try flushPlainRun()
        return true
    }

    private func encodePuppetClipCompositeDraw(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        meshes: [WPEPuppetMesh],
        partSelection: PuppetPartSelection,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        loadAction: MTLLoadAction,
        clearColor: MTLClearColor,
        primary: MTLTexture,
        mask: MTLTexture,
        clipTexture: MTLTexture?,
        vertexName: String,
        fragmentName: String,
        blendMode: String,
        hasMask: Bool,
        clipMode: Float,
        meshUniforms: inout WPEPuppetMeshUniforms,
        paletteState: (bonePalette: [simd_float4x4], skinningEnabled: Float),
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(WPEMetalPipelineCache.cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthCache.stencilState(depthTest: "disabled", depthWrite: "disabled"))
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: blendMode,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: .invalid
        ))
        encoder.setFragmentTexture(primary, index: 0)
        encoder.setFragmentTexture(mask, index: 1)
        if let clipTexture {
            encoder.setFragmentTexture(clipTexture, index: 8)
        }

        var uniforms = genericImageUniforms(for: pass, layer: layer, hasMask: hasMask)
        uniforms.alphaMaskUV.w = clipMode
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(&meshUniforms, length: MemoryLayout<WPEPuppetMeshUniforms>.stride, index: 1)
        try drawPuppetMeshes(meshes, encoder: encoder, partSelection: partSelection)
    }

    private func drawPuppetMeshes(
        _ meshes: [WPEPuppetMesh],
        encoder: MTLRenderCommandEncoder,
        partSelection: PuppetPartSelection = .all
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
                guard partSelection.isAll else { continue }
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indices.count,
                    indexType: .uint16,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
            } else {
                for part in mesh.parts where part.count > 0 && partSelection.contains(part) {
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
            return layer.parallaxDepth != SIMD2<Double>(0, 0) && cameraParallax.smoothed != SIMD2<Float>(0, 0)
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
            // A compose layer that parents children is a layer-group container, not
            // a scene-effect box: its children render flat, so confining its own
            // passthrough to the authored box would paint a scene-copy PiP. Keep it
            // fullscreen (identity passthrough = invisible).
            if groupingContainerObjectIDs.contains(layer.objectID) { return false }
            return WPEMetalSceneCaptureUtilityModels.outputGeometry(
                path: layer.imagePath,
                geometry: layer.geometry,
                sceneSize: currentSceneSize
            ) == .subregion
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
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        if isOutputPoolingEnabled {
            outputTexturePool.removeAll { $0.width != width || $0.height != height }
            if let recycled = outputTexturePool.first(where: isOutputTextureReusable) {
                noteVendedOutputTexture(recycled)
                return recycled
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.outputPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor output"
        if isOutputPoolingEnabled {
            outputTexturePool.append(texture)
            // Steady state needs 3 (in-render + re-presented latest + history);
            // anything beyond that came from transient stalls — let ARC reap
            // the dropped one once its holders release it.
            if outputTexturePool.count > 4 {
                outputTexturePool.removeFirst()
            }
        }
        noteVendedOutputTexture(texture)
        return texture
    }

    private func isOutputTextureReusable(_ texture: MTLTexture) -> Bool {
        let id = ObjectIdentifier(texture)
        if recentOutputTextureIDs.contains(id) {
            return false
        }
        if let history = previousFrameHistory?.sceneTexture, history === texture {
            return false
        }
        return !presentTracker.isInFlight(id)
    }

    private func noteVendedOutputTexture(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        recentOutputTextureIDs.removeAll { $0 == id }
        recentOutputTextureIDs.append(id)
        // Keep the last `maxFramesInFlight` vended targets out of the reuse set:
        // under async submission their render may still be running, and the
        // in-flight semaphore guarantees it has finished by the time the target
        // ages out of this window. Keep at least 2 for the static-scene re-present
        // + `previousFrameHistory` reads even when only 1 frame is in flight.
        let retain = max(2, Self.maxFramesInFlight)
        if recentOutputTextureIDs.count > retain {
            recentOutputTextureIDs.removeFirst(recentOutputTextureIDs.count - retain)
        }
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
        // Bootstrap textures are read-only for their whole life (writes go to
        // the pool/output, never to the seeded `.previous` source), so one
        // cleared allocation per (target, size, format) serves every frame —
        // previously this allocated + cleared a scene-sized texture per frame.
        let key = BootstrapPreviousKey(
            targetID: targetID,
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        if let cached = bootstrapPreviousTextureCache[key] {
            return cached
        }
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

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = cleared
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = clearColor(for: targetID)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.endEncoding()
        bootstrapPreviousTextureCache[key] = cleared
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
            Logger.info(
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
            state = try WPEMetalCompileTimer.measure { try device.makeRenderPipelineState(descriptor: descriptor) }
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
            return try WPEMetalTranspileTimer.measure {
                try processor.process(
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
            }
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
        guard let request = try Self.makeCompileRequest(for: pass, recordFailure: true) else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
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
