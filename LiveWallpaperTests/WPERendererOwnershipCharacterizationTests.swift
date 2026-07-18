#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Metal
    import Testing

    /// AF-06 E1 inventory and extraction requirements for the current WPE runtime.
    ///
    /// These tests deliberately do not construct a Metal device, MTKView, window, or
    /// corpus renderer. Source contracts describe the production owners that exist
    /// today; the small pure matrices describe the boundary an eventual extraction
    /// must preserve. They are not evidence that assets are already shared, or that
    /// sharing will reduce memory. AF-06 remains gated on the RR-03/RR-14 oracles and
    /// signed-host 1/2/4-screen same/different-scene measurements.
    @Suite("AF-06 WPE renderer ownership inventory")
    struct WPERendererOwnershipCharacterizationTests {
        @Test("production declarations inventory mutable, immutable, and process-shared owners")
        func productionOwnerInventory() throws {
            let renderer = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift"
            )
            let rendererFamily = try RepositoryRoot.componentSource(
                under: "LiveWallpaper/Runtime/Metal",
                namePrefix: "WPEMetalSceneRenderer"
            )
            let executor = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor.swift"
            )
            let executorFamily = try RepositoryRoot.componentSource(
                under: "LiveWallpaper/Runtime/Metal",
                namePrefix: "WPEMetalRenderExecutor"
            )
            let preparedPipeline = try RepositoryRoot.source(
                "LiveWallpaper/Models/WPERenderPipeline.swift"
            )
            let frameState = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalFrameState.swift"
            )
            let uploadQueue = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalTextureUploadQueue.swift"
            )
            let metadata = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalTextureMetadataRegistry.swift"
            )
            let textureLoader = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalTextureLoader.swift"
            )
            let sessionBuilder = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Session/AmbientWallpaperSessionBuilder.swift"
            )
            let sceneSession = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Session/SceneWallpaperSession.swift"
            )

            let evidence: [SourceEvidence] = [
                // One renderer is constructed for every scene session today. These
                // roots own mutable display/session state and remain per session.
                SourceEvidence(
                    owner: "per-session mutable renderer roots",
                    source: renderer,
                    needles: [
                        // M2c1b-3c: the renderer holds the surface's Sendable seams
                        // (control handle + present layer), not the surface itself.
                        "let surfaceControl: any WPESurfaceControl",
                        "let metalLayer: WPEPresentLayer",
                        "let executor: WPEMetalRenderExecutor",
                        "var outputTexture: MTLTexture?",
                    ]
                ),
                // Current placement is per renderer, but that alone does not make
                // immutable content inputs/helpers ineligible for later extraction.
                SourceEvidence(
                    owner: "currently per-renderer immutable inputs and helpers",
                    source: renderer,
                    needles: [
                        "let descriptor: SceneDescriptor",
                        "let dependencyMounts: [WPEAssetMount]",
                        "let resourceResolver: WPEMultiRootResourceResolver",
                        "let textureLoader: WPEMetalTextureLoader",
                    ]
                ),
                SourceEvidence(
                    owner: "per-scene particles, text, audio, and scripts",
                    source: renderer,
                    needles: [
                        "var particleSystems: [WPEParticleSystem] = []",
                        "var textObjects: [WPESceneTextObject] = []",
                        "var soundRuntime: WPESoundRuntime?",
                        "var sceneScriptSharedState: WPESharedScriptState?",
                        "var layerScriptInstances: [String: WPELayerScriptInstance]",
                        "var liveCreatedLayers: [String: WPECreatedLayerScriptState]",
                    ]
                ),
                SourceEvidence(
                    owner: "per-scene video and texture residency",
                    source: renderer,
                    needles: [
                        "var loadedTextures: [String: MTLTexture] = [:]",
                        "var dynamicTextureSources: [String: WPEDynamicTextureSource]",
                        "var onDemandVideoKeyByID: [String: String] = [:]",
                        "var onDemandVideoLoading: Set<String> = []",
                        "var introPhaseSource: WPEVideoTextureSource?",
                        "var staticTextureCacheRecords: [String: StaticTextureCacheRecord]",
                    ]
                ),
                SourceEvidence(
                    owner: "per-display interaction and frame history",
                    source: renderer,
                    needles: [
                        "var currentProfile: WallpaperPerformanceProfile = .quality",
                        "var mouseInteractionEnabled = true",
                        "var previousPointer = SIMD2<Double>(0.5, 0.5)",
                        "var previousLayerScriptPointerFrame = WPEPointerFrame.neutral",
                        "var lastRuntimeUniforms: WPEMetalRuntimeUniforms?",
                        "var lastFramePipeline: WPEPreparedRenderPipeline?",
                    ]
                ),
                SourceEvidence(
                    owner: "renderer load generation and renderer-retained deferred-audio task",
                    source: renderer,
                    needles: [
                        "var didLoad = false",
                        "var loadGeneration = 0",
                        "var deferredAudioStartupTask: Task<Void, Never>?",
                        "var pendingAudioStartupDocument: WPESceneDocument?",
                    ]
                ),
                // The executor is currently created inside each renderer. Its Metal
                // device is therefore an implicit cache-identity component.
                SourceEvidence(
                    owner: "per-renderer executor and device scope",
                    source: executor,
                    needles: [
                        "let device: MTLDevice",
                        "let commandQueue: MTLCommandQueue",
                        "let targetPool: WPEMetalRenderTargetPool",
                        "let depthCache: WPEMetalDepthStateCache",
                        "private let pipelineCache: WPEMetalPipelineCache",
                    ]
                ),
                SourceEvidence(
                    owner: "per-renderer immutable-result caches",
                    source: executor,
                    needles: [
                        "var translatedShaderCache: [String: WPEShaderCompileResult] = [:]",
                        "private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]",
                        "private var customSamplerStateCache: [Int: MTLSamplerState] = [:]",
                        "var msdfTextPipelineCache: [MSDFTextPipelineKey: MTLRenderPipelineState] = [:]",
                    ]
                ),
                SourceEvidence(
                    owner: "per-renderer mutable render histories and pools",
                    source: executor,
                    needles: [
                        "var previousFrameHistory: PreviousFrameHistory?",
                        "var outputTexturePool: [MTLTexture] = []",
                        "var recentOutputTextureIDs: [ObjectIdentifier] = []",
                        "var bootstrapPreviousTextureCache: [BootstrapPreviousKey: MTLTexture] = [:]",
                        "var sceneReadHazardSnapshotCache: [BootstrapPreviousKey: MTLTexture] = [:]",
                    ]
                ),
                // These caches are not cleared by releaseTransientResources;
                // they live until their executor/session is destroyed today.
                SourceEvidence(
                    owner: "executor-lifetime reload survivors",
                    source: executor,
                    needles: [
                        "let depthCache: WPEMetalDepthStateCache",
                        "private let pipelineCache: WPEMetalPipelineCache",
                        "var translatedShaderCache: [String: WPEShaderCompileResult] = [:]",
                        "private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]",
                        "private var customSamplerStateCache: [Int: MTLSamplerState] = [:]",
                        "var msdfTextPipelineCache: [MSDFTextPipelineKey: MTLRenderPipelineState] = [:]",
                        "var msdfNeutralWhiteTexture: MTLTexture?",
                        "var textOverlayPipelineCache: [UInt: MTLRenderPipelineState] = [:]",
                        "var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]",
                        "var sceneReadHazardSnapshotCache: [BootstrapPreviousKey: MTLTexture] = [:]",
                        "var refractionBackground: MTLTexture?",
                    ]
                ),
                // Prepared graph/pipeline values are immutable plans, but their
                // renderer slots and GPU outputs remain instance-owned above.
                SourceEvidence(
                    owner: "immutable prepared pipeline values",
                    source: preparedPipeline,
                    needles: [
                        "struct WPEPreparedRenderPipeline: Equatable, Sendable",
                        "let layers: [WPEPreparedRenderLayer]",
                        "let graphLayer: WPERenderLayer",
                        "let passes: [WPEPreparedRenderPass]",
                        "let shader: WPEShaderProgram?",
                        "let comboValues: [String: Int]",
                    ]
                ),
                SourceEvidence(
                    owner: "PSO and target option identity",
                    source: frameState + executorFamily,
                    needles: [
                        "struct WPEMetalPipelineKey: Hashable",
                        "let vertexName: String",
                        "let fragmentName: String",
                        "let blendMode: String",
                        "let colorPixelFormat: MTLPixelFormat",
                        "let depthPixelFormat: MTLPixelFormat",
                        "let libraryID: ObjectIdentifier",
                    ]
                ),
                // These are the actual process-wide mutable owners. They coordinate
                // work/metadata; none is a scene GPU-asset registry.
                SourceEvidence(
                    owner: "process-shared bounded upload admission",
                    source: uploadQueue + textureLoader,
                    needles: [
                        "static let shared = WPEMetalTextureUploadQueue(",
                        "private var waiterOrder: [UUID] = []",
                        "private var waiters: [UUID: Waiter] = [:]",
                        "private var grantedRequestIDs: Set<UUID> = []",
                        "uploadQueue: WPEMetalTextureUploadQueue = .shared",
                    ]
                ),
                SourceEvidence(
                    owner: "process-shared weak texture metadata",
                    source: metadata,
                    needles: [
                        "static let shared = WPEMetalTextureMetadataRegistry()",
                        "weak var texture: MTLTexture?",
                        "private var resolutions: [ObjectIdentifier: Entry] = [:]",
                        "resolutions[key] = Entry(texture: texture, resolution: resolution)",
                    ]
                ),
                SourceEvidence(
                    owner: "diagnostic and disk-cache singletons",
                    source: rendererFamily + executorFamily,
                    needles: [
                        "WPEVideoTextureDiskCache.shared.store(",
                        "WPESceneDebugArtifacts.shared.beginSession(",
                        "WPECanonicalTraceRecorder.shared.beginScene(",
                        "snapshotter: WPEMetalTextureSnapshotter = .shared",
                    ]
                ),
                SourceEvidence(
                    owner: "session factory creates a fresh renderer",
                    source: sessionBuilder,
                    needles: [
                        "func makeSceneSession(",
                        "renderer = try WPEMetalSceneRenderer(",
                        // M2c1b-3c: the session owns the render actor + surface; the
                        // renderer is adopted into the actor, not held by the session.
                        "let session = SceneWallpaperSession(window: window, renderActor: renderActor, surface: surface)",
                        // Adopt+load now runs inside a session-owned startup task so
                        // cleanup can cancel/drain it before teardown (was a detached task).
                        "session.startAdoptingRenderer(",
                    ]
                ),
                SourceEvidence(
                    owner: "session-owned load task and publication generation",
                    source: sceneSession,
                    needles: [
                        "private let renderActor: WPEDisplayRenderActor",
                        "private var loadTask: Task<Void, Never>?",
                        "private var loadGeneration = 0",
                        "loadTask?.cancel()",
                        "await previous.value",
                        "guard self.loadGeneration == generation else { return }",
                    ]
                ),
            ]

            for item in evidence {
                for needle in item.needles {
                    #expect(
                        item.source.contains(needle),
                        Comment(rawValue: "Missing AF-06 evidence for \(item.owner): \(needle)")
                    )
                }
            }
        }

        @Test("production write sites lock session load reload cleanup and transient release")
        func lifecycleWriteSites() throws {
            let loadSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
            )
            let lifecycleSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
            )
            let textureSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Textures.swift"
            )
            let frameSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
            )
            let scriptSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift"
            )
            let scriptContainmentSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift"
            )
            let executorSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor.swift"
            )
            let targetSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor+Targets.swift"
            )
            let sceneSessionSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Session/SceneWallpaperSession.swift"
            )

            // M2c1b-3c: the async surfaces carry the render-actor isolation.
            let load = try sourceBlock(loadSource, from: "func load(on actor: isolated WPEDisplayRenderActor) async throws")
            let performLoad = try sourceBlock(loadSource, from: "private func performLoad(")
            let reload = try sourceBlock(lifecycleSource, from: "func reload(on actor: isolated WPEDisplayRenderActor) async throws")
            let cleanup = try sourceBlock(lifecycleSource, from: "func cleanup()")
            let releaseDynamic = try sourceBlock(textureSource, from: "func releaseDynamicTextureSources()")
            let renderFrame = try sourceBlock(frameSource, from: "func renderCurrentFrame(inputs: WPEFrameInputs) throws")
            let encodeFrame = try sourceBlock(frameSource, from: "func encodeSceneFrame(")
            let clearScriptRuntime = try sourceBlock(
                scriptContainmentSource,
                from: "func clearSceneScriptRuntimeState()"
            )
            let lazyVideo = try sourceBlock(scriptSource, from: "private func lazyLoadVideo(key:")
            let releaseTransient = try sourceBlock(targetSource, from: "func releaseTransientResources()")
            let sessionCleanup = try sourceBlock(sceneSessionSource, from: "func cleanup()")
            let sessionStart = try sourceBlock(sceneSessionSource, from: "func beginLoad() async")
            let sessionReload = try sourceBlock(sceneSessionSource, from: "func reload() async")
            let sessionRunLoad = try sourceBlock(sceneSessionSource, from: "private func runLoadViaActor()")

            expectContains(
                load,
                owner: "load entry",
                [
                    "guard !didLoad else { return }",
                    "loadGeneration &+= 1",
                    "let scriptLoadToken = sceneScriptLoadState.begin(generation: generation)",
                    "try await performLoad(scriptLoadToken: scriptLoadToken, on: actor)",
                    "try checkCurrentSceneScriptLoad(scriptLoadToken)",
                ]
            )
            expectContains(
                performLoad,
                owner: "load publication",
                [
                    "try Task.checkCancellation()",
                    "Task.detached(priority: .userInitiated)",
                    "renderGraph = graph",
                    "renderPipeline = pipeline",
                    "outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())",
                    "didLoad = true",
                ]
            )
            expectContains(
                reload,
                owner: "reload teardown",
                [
                    "loadGeneration &+= 1",
                    "deferredAudioStartupTask?.cancel()",
                    "releaseDynamicTextureSources()",
                    "clearSceneScriptRuntimeState()",
                    "executor.releaseTransientResources()",
                    "try await load(on: actor)",
                ]
            )
            expectContains(
                cleanup,
                owner: "terminal cleanup",
                [
                    "loadGeneration &+= 1",
                    "deferredAudioStartupTask?.cancel()",
                    "surfaceControl.detach()",
                    "releaseDynamicTextureSources()",
                    "soundRuntime?.stop()",
                    "executor.releaseTransientResources()",
                    "stopEngineAssetsAccessIfNeeded()",
                ]
            )
            expectContains(
                releaseDynamic,
                owner: "dynamic texture teardown",
                [
                    "dynamicTextureSources.values.forEach { $0.invalidate() }",
                    "dynamicTextureSources.removeAll()",
                    "loadedTextures.removeAll()",
                    "resetTextureCacheBudgetState()",
                ]
            )
            expectContains(
                renderFrame,
                owner: "per-frame writes",
                ["lastFramePipeline = framePipeline", "encodeSceneFrame("]
            )
            expectContains(
                encodeFrame,
                owner: "per-frame executor publication",
                ["try executor.render(", "return frame"]
            )
            expectContains(
                clearScriptRuntime,
                owner: "scene-script runtime teardown",
                ["sceneScriptSharedState = nil", "lastStableScriptTransforms = LiveScriptTransforms()"]
            )
            #expect(frameSource.contains("previousPointer = pointer"))
            #expect(frameSource.contains("lastRuntimeUniforms = uniforms"))
            // M2c1b-3c: the rebuild's generation gating and loading-set cleanup
            // moved into the render actor's named entry; the schedule site only
            // admits + dispatches. Same intent, split across the two sources.
            let renderActorSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/RenderThread/WPEDisplayRenderActor.swift"
            )
            let rebuildVideo = try sourceBlock(renderActorSource, from: "func rebuildOnDemandVideo(")
            expectContains(
                lazyVideo,
                owner: "on-demand video task",
                [
                    "onDemandVideoLoading.insert(key)",
                    "let generation = loadGeneration",
                    "Task { [actor] in",
                    "await actor.rebuildOnDemandVideo(key: key, generation: generation)",
                ]
            )
            expectContains(
                rebuildVideo,
                owner: "on-demand video rebuild gating",
                [
                    "defer { renderer.onDemandVideoLoading.remove(key) }",
                    "guard renderer.loadGeneration == generation else { return }",
                ]
            )
            #expect(executorSource.contains("previousFrameHistory = PreviousFrameHistory("))
            expectContains(
                releaseTransient,
                owner: "executor transient release",
                [
                    "targetPool.releaseAll()",
                    "previousFrameHistory = nil",
                    "outputTexturePool.removeAll()",
                    "bootstrapPreviousTextureCache.removeAll()",
                    "compiledShaderResultByPassID.removeAll()",
                ]
            )
            // Per-pass IDs and frame/target history are cleared. The declarations
            // below all survive current scene reloads until executor destruction;
            // inventorying that lifetime does not imply they are safe to share.
            #expect(releaseTransient.contains("content-keyed translatedShaderCache is safe to persist"))
            let reloadPersistentExecutorOwners = [
                "translatedShaderCache",
                "translatedPipelineCache",
                "customSamplerStateCache",
                "msdfTextPipelineCache",
                "msdfNeutralWhiteTexture",
                "textOverlayPipelineCache",
                "particlePipelineCache",
                "sceneReadHazardSnapshotCache",
                // Mutable per-executor scratch, never an immutable share candidate.
                "refractionBackground",
                "pipelineCache",
                "depthCache",
            ]
            for owner in reloadPersistentExecutorOwners {
                #expect(executorSource.contains(owner))
                #expect(!releaseTransient.contains("\(owner).removeAll"))
                #expect(!releaseTransient.contains("\(owner) ="))
            }

            // SceneWallpaperSession owns the retained load task and a generation
            // independent of the renderer generation. Reload cancels and drains the
            // old task before mutating the renderer, then only the newest task may
            // publish errors or clear the retained task handle.
            // Terminal cleanup cancels then DRAINS the startup + load tasks before
            // tearing the renderer down, so teardown never runs ahead of an in-flight
            // adopt/load (which would touch an already-stopped actor).
            expectOrder(
                [
                    "window?.close()",
                    "loadTask?.cancel()",
                    "startup?.cancel()",
                    "await startup?.value",
                    "await load?.value",
                    "await actor.teardownRenderer()",
                    "actor.shutdown()",
                ],
                in: sessionCleanup,
                owner: "session cleanup drains in-flight startup/load before teardown"
            )
            expectOrder(
                [
                    "loadGeneration += 1",
                    "let generation = loadGeneration",
                    "let task = Task",
                    "await self.runLoadViaActor()",
                    "loadTask = task",
                    "await task.value",
                    "if loadGeneration == generation",
                    "loadTask = nil",
                ],
                in: sessionStart,
                owner: "session initial load"
            )
            expectOrder(
                [
                    "loadTask?.cancel()",
                    "if let previous = loadTask",
                    "await previous.value",
                    "loadTask = nil",
                    "loadGeneration += 1",
                    "let generation = loadGeneration",
                    "let task = Task",
                    "try await self.renderActor.reload()",
                    "self.loadGeneration == generation",
                    "self.loadError = nil",
                ],
                in: sessionReload,
                owner: "session reload cancel-drain-newest-wins"
            )
            expectOrder(
                [
                    "loadTask = task",
                    "await task.value",
                    "if loadGeneration == generation",
                    "loadTask = nil",
                ],
                in: sessionReload,
                owner: "session reload task-handle release"
            )
            expectOrder(
                [
                    "try await renderActor.load()",
                    "guard !Task.isCancelled else { return }",
                    "loadError = nil",
                    "loadProgress = nil",
                ],
                in: sessionRunLoad,
                owner: "session initial-load publication"
            )
        }

        @Test("loader and upload work are generation-gated and cancellation-owned")
        func loaderUploadAndCancellationInventory() throws {
            let renderer = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift"
            )
            let loadSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
            )
            let textureSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Textures.swift"
            )
            let staticReloadSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+StaticTextureReload.swift"
            )
            let uploadSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalTextureUploadQueue.swift"
            )
            let lifecycleSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
            )
            let reloadOwnerSource = try RepositoryRoot.source(
                "LiveWallpaper/Runtime/Metal/WPEStaticTextureReloadTaskOwner.swift"
            )

            // M2c1b-3c: loadTextures gained the render-actor isolation parameter
            // (multi-line signature), and the reload body moved into the actor-run
            // `performStaticTextureReload` — the schedule site only admits/dispatches.
            let loadTextures = try sourceBlock(textureSource, from: "func loadTextures(")
            let staticReload = try sourceBlock(staticReloadSource, from: "func scheduleStaticTextureReload(for path:")
            let staticReloadBody = try sourceBlock(staticReloadSource, from: "func performStaticTextureReload(")
            let upload = try sourceBlock(uploadSource, from: "func perform<T>(")
            let rendererLoad = try sourceBlock(loadSource, from: "func load(on actor: isolated WPEDisplayRenderActor) async throws")
            let rendererReload = try sourceBlock(lifecycleSource, from: "func reload(on actor: isolated WPEDisplayRenderActor) async throws")
            let rendererCleanup = try sourceBlock(lifecycleSource, from: "func cleanup()")

            expectContains(
                loadTextures,
                owner: "structured texture-load group",
                [
                    "let generation = loadGeneration",
                    "withThrowingTaskGroup",
                    "try Task.checkCancellation()",
                    "guard loadGeneration == generation else",
                    "group.cancelAll()",
                    "recordLoadedStaticTexture(",
                ]
            )
            expectContains(
                staticReload,
                owner: "retained static reload task",
                [
                    "guard didLoad",
                    "let generation = loadGeneration",
                    "owner.submit(path: path, generation: generation)",
                    "actor.performStaticReload(",
                ]
            )
            expectContains(
                staticReloadBody,
                owner: "static reload publication gates",
                [
                    "!Task.isCancelled",
                    "loadGeneration == generation",
                    "staticTextureReloadTaskOwner.canPublish(ticket)",
                    "catch is CancellationError",
                ]
            )
            expectContains(
                reloadOwnerSource,
                owner: "generation-scoped reload task owner",
                [
                    "private var handles: [String: Handle] = [:]",
                    "private(set) var isAccepting = false",
                    "currentGeneration == generation",
                    "let ticket = Ticket(path: path, generation: generation, token: UUID())",
                    "func quiesce() -> Drain",
                    "handles.removeAll(keepingCapacity: false)",
                    "tasks.forEach { $0.cancel() }",
                    "handles[ticket.path]?.ticket.token == ticket.token",
                ]
            )
            expectContains(
                upload,
                owner: "process upload admission",
                [
                    "let permit = try await admission.acquire()",
                    "defer { permit.release() }",
                    "try Task.checkCancellation()",
                    "withCheckedThrowingContinuation",
                    "executor.execute",
                    "cancellationState.tryBegin()",
                ]
            )

            expectOrder(
                [
                    "try await performLoad(scriptLoadToken: scriptLoadToken, on: actor)",
                    "try Task.checkCancellation()",
                    "try checkCurrentSceneScriptLoad(scriptLoadToken)",
                    "staticTextureReloadTaskOwner.resume(generation: generation)",
                ],
                in: rendererLoad,
                owner: "reload admission opens after load completion"
            )
            expectOrder(
                [
                    "didLoad = false",
                    "let staticTextureReloadDrain = await staticTextureReloadTaskOwner.quiesce()",
                    "loadGeneration &+= 1",
                    "await staticTextureReloadDrain.wait()",
                    "releaseDynamicTextureSources()",
                    "try await load(on: actor)",
                ],
                in: rendererReload,
                owner: "renderer reload task drain"
            )
            // Cleanup is synchronous on the render actor; the @MainActor owner is
            // quiesced through a fire-and-forget hop (Drain intentionally dropped).
            expectOrder(
                [
                    "didLoad = false",
                    "Task { [owner = staticTextureReloadTaskOwner] in _ = await owner.quiesce() }",
                    "loadGeneration &+= 1",
                    "releaseDynamicTextureSources()",
                ],
                in: rendererCleanup,
                owner: "renderer cleanup task cancellation"
            )
            #expect(renderer.contains("var deferredAudioStartupTask: Task<Void, Never>?"))
            #expect(renderer.contains("let staticTextureReloadTaskOwner = WPEStaticTextureReloadTaskOwner()"))
            #expect(!renderer.contains("var loadTask:"))
        }

        @Test("real PSO and render-target keys include output-affecting options")
        func productionPureIdentityKeys() {
            let basePSO = pipelineKey()
            let psoVariants: Set<WPEMetalPipelineKey> = [
                basePSO,
                pipelineKey(vertex: "wpe_object_quad_vertex"),
                pipelineKey(fragment: "wpe_copy_fragment"),
                pipelineKey(blend: "additive"),
                pipelineKey(color: .rgba16Float),
                pipelineKey(depth: .depth32Float),
            ]
            #expect(psoVariants.count == 6)

            let baseTarget = WPEMetalRenderTargetKey(
                name: "scene",
                width: 1920,
                height: 1080,
                format: "rgba8",
                pixelFormat: .rgba8Unorm_srgb
            )
            let targetVariants: Set<WPEMetalRenderTargetKey> = [
                baseTarget,
                WPEMetalRenderTargetKey(
                    name: "scene",
                    width: 3840,
                    height: 2160,
                    format: "rgba8",
                    pixelFormat: .rgba8Unorm_srgb
                ),
                WPEMetalRenderTargetKey(
                    name: "scene",
                    width: 1920,
                    height: 1080,
                    format: "rgba16f",
                    pixelFormat: .rgba16Float
                ),
            ]
            #expect(targetVariants.count == 3)
        }

        @Test("extraction requirement: two-generation newest-wins publication matrix")
        func extractionRequirementPublicationMatrix() {
            var lifecycle = SceneLoadExtractionRequirement(sessionID: "screen-A")
            let initialParse = lifecycle.beginLoad(sceneID: "scene-1", stage: .parse)
            #expect(lifecycle.canPublish(initialParse, cancelled: false))

            let replacementUpload = lifecycle.beginReload(sceneID: "scene-2", stage: .upload)
            #expect(replacementUpload.sessionGeneration > initialParse.sessionGeneration)
            #expect(replacementUpload.rendererGeneration > initialParse.rendererGeneration)
            #expect(!lifecycle.canPublish(initialParse, cancelled: false))
            #expect(lifecycle.canPublish(replacementUpload, cancelled: false))

            let cases = [
                RequirementPublicationCase(
                    name: "cancel during parse",
                    ticket: lifecycle.ticket(stage: .parse),
                    cancelled: true,
                    expectedPublish: false
                ),
                RequirementPublicationCase(
                    name: "cancel during upload",
                    ticket: lifecycle.ticket(stage: .upload),
                    cancelled: true,
                    expectedPublish: false
                ),
                RequirementPublicationCase(
                    name: "fresh parse completion",
                    ticket: lifecycle.ticket(stage: .parse),
                    cancelled: false,
                    expectedPublish: true
                ),
                RequirementPublicationCase(
                    name: "late old-generation completion",
                    ticket: initialParse,
                    cancelled: false,
                    expectedPublish: false
                ),
            ]
            for row in cases {
                #expect(
                    lifecycle.canPublish(row.ticket, cancelled: row.cancelled) == row.expectedPublish,
                    Comment(rawValue: row.name)
                )
            }

            let completionAfterCleanup = lifecycle.ticket(stage: .upload)
            lifecycle.cleanup()
            #expect(!lifecycle.canPublish(completionAfterCleanup, cancelled: false))
            #expect(lifecycle.activeSceneID == nil)
        }

        @Test("extraction requirement: same-scene screens match only a minimum candidate key")
        func minimumMultiScreenCandidateIdentityMatrix() {
            let options = MinimumImmutableCompileOptionsCandidate(
                shaderABI: "wpe-metal-v1",
                pipelineKeyFingerprint: "fullscreen|generic|normal|rgba8-srgb|invalid",
                translationOptionsFingerprint: "glsl-es|combos-v1|transpiler-v1",
                textureMetadataPolicyFingerprint: "srgb|clamp|linear|source-resolution",
                colorFormat: "rgba8Unorm_srgb",
                depthFormat: "invalid",
                hdr: false
            )
            let sameSceneA = MinimumImmutableAssetCandidateIdentity(
                deviceRegistryID: 100,
                contentHash: "scene-one-hash",
                options: options
            )
            let sameSceneB = MinimumImmutableAssetCandidateIdentity(
                deviceRegistryID: 100,
                contentHash: "scene-one-hash",
                options: options
            )
            #expect(sameSceneA == sameSceneB)

            let screenA = MutableSceneOwnerIdentity(screenID: 1, sceneID: "scene-1", generation: 1)
            let screenB = MutableSceneOwnerIdentity(screenID: 2, sceneID: "scene-1", generation: 1)
            #expect(screenA != screenB)
            #expect(screenA.reloaded() != screenA)

            let differentScene = MinimumImmutableAssetCandidateIdentity(
                deviceRegistryID: 100,
                contentHash: "scene-two-hash",
                options: options
            )
            let differentDevice = MinimumImmutableAssetCandidateIdentity(
                deviceRegistryID: 200,
                contentHash: "scene-one-hash",
                options: options
            )
            let differentOptions = MinimumImmutableAssetCandidateIdentity(
                deviceRegistryID: 100,
                contentHash: "scene-one-hash",
                options: MinimumImmutableCompileOptionsCandidate(
                    shaderABI: "wpe-metal-v1",
                    pipelineKeyFingerprint: "fullscreen|generic|normal|rgba16f|invalid",
                    translationOptionsFingerprint: "glsl-es|combos-v1|transpiler-v1",
                    textureMetadataPolicyFingerprint: "srgb|clamp|linear|source-resolution",
                    colorFormat: "rgba16Float",
                    depthFormat: "invalid",
                    hdr: true
                )
            )
            #expect(sameSceneA != differentScene)
            #expect(sameSceneA != differentDevice)
            #expect(sameSceneA != differentOptions)

            // Candidate equality is not sharing. Current production constructs one
            // renderer/executor per session and has no immutable asset registry.
            #expect(Set([sameSceneA, sameSceneB, differentScene, differentDevice, differentOptions]).count == 4)
        }

        private func pipelineKey(
            vertex: String = "wpe_fullscreen_vertex",
            fragment: String = "wpe_generic_fragment",
            blend: String = "normal",
            color: MTLPixelFormat = .rgba8Unorm_srgb,
            depth: MTLPixelFormat = .invalid
        ) -> WPEMetalPipelineKey {
            WPEMetalPipelineKey(
                vertexName: vertex,
                fragmentName: fragment,
                blendMode: blend,
                colorPixelFormat: color,
                depthPixelFormat: depth
            )
        }

        private func expectContains(
            _ source: String,
            owner: String,
            _ needles: [String]
        ) {
            for needle in needles {
                #expect(
                    source.contains(needle),
                    Comment(rawValue: "Missing AF-06 write-site evidence for \(owner): \(needle)")
                )
            }
        }

        private func expectOrder(
            _ needles: [String],
            in source: String,
            owner: String
        ) {
            var searchStart = source.startIndex
            for needle in needles {
                let range = source.range(of: needle, range: searchStart ..< source.endIndex)
                #expect(
                    range != nil,
                    Comment(rawValue: "Missing or out-of-order AF-06 evidence for \(owner): \(needle)")
                )
                guard let range else { return }
                searchStart = range.upperBound
            }
        }

        private func sourceBlock(_ source: String, from startNeedle: String) throws -> String {
            guard let start = source.range(of: startNeedle),
                  let openingBrace = source[start.lowerBound...].firstIndex(of: "{") else {
                throw RendererOwnershipFixtureError.missingSourceBoundary(startNeedle)
            }

            var depth = 0
            var index = openingBrace
            while index < source.endIndex {
                switch source[index] {
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(source[start.lowerBound ... index])
                    }
                default:
                    break
                }
                index = source.index(after: index)
            }
            throw RendererOwnershipFixtureError.missingSourceBoundary(startNeedle)
        }
    }

    private struct SourceEvidence {
        let owner: String
        let source: String
        let needles: [String]
    }

    private enum RequirementWorkStage: String, Hashable {
        case parse
        case upload
    }

    private struct SceneLoadRequirementTicket: Hashable {
        let sessionID: String
        let sessionGeneration: Int
        let rendererGeneration: Int
        let stage: RequirementWorkStage
    }

    /// A future extraction requirement, not a model of production implementation.
    /// The source/order assertions above lock the two real generation owners. This
    /// pure matrix says an extracted publisher must reject either stale epoch and a
    /// cancelled final publication. It does not claim cancellation prevents partial
    /// renderer state writes, upload work from starting, or resource retention.
    private struct SceneLoadExtractionRequirement {
        let sessionID: String
        private(set) var sessionGeneration = 0
        private(set) var rendererGeneration = 0
        private(set) var activeSceneID: String?

        mutating func beginLoad(sceneID: String, stage: RequirementWorkStage) -> SceneLoadRequirementTicket {
            sessionGeneration &+= 1
            rendererGeneration &+= 1
            activeSceneID = sceneID
            return ticket(stage: stage)
        }

        mutating func beginReload(sceneID: String, stage: RequirementWorkStage) -> SceneLoadRequirementTicket {
            // Session reload advances once; renderer reload invalidates its prior
            // epoch, and renderer.load() advances again for the replacement load.
            sessionGeneration &+= 1
            rendererGeneration &+= 2
            activeSceneID = nil
            activeSceneID = sceneID
            return ticket(stage: stage)
        }

        func ticket(stage: RequirementWorkStage) -> SceneLoadRequirementTicket {
            SceneLoadRequirementTicket(
                sessionID: sessionID,
                sessionGeneration: sessionGeneration,
                rendererGeneration: rendererGeneration,
                stage: stage
            )
        }

        func canPublish(_ ticket: SceneLoadRequirementTicket, cancelled: Bool) -> Bool {
            !cancelled
                && activeSceneID != nil
                && ticket.sessionID == sessionID
                && ticket.sessionGeneration == sessionGeneration
                && ticket.rendererGeneration == rendererGeneration
        }

        mutating func cleanup() {
            sessionGeneration &+= 1
            rendererGeneration &+= 1
            activeSceneID = nil
        }
    }

    private struct RequirementPublicationCase {
        let name: String
        let ticket: SceneLoadRequirementTicket
        let cancelled: Bool
        let expectedPublish: Bool
    }

    /// Deliberately minimum—and explicitly incomplete—candidate identity for a
    /// future immutable extraction. A production registry key must be derived from
    /// full production identities: Metal device/library/source, vertex + fragment,
    /// blend + pixel formats, shader combos/transpiler ABI, and texture decode,
    /// sampling, clamp, interpolation, color-space, and resolution metadata.
    /// Production has no owner keyed by this type today.
    private struct MinimumImmutableAssetCandidateIdentity: Hashable {
        let deviceRegistryID: UInt64
        let contentHash: String
        let options: MinimumImmutableCompileOptionsCandidate
    }

    private struct MinimumImmutableCompileOptionsCandidate: Hashable {
        let shaderABI: String
        let pipelineKeyFingerprint: String
        let translationOptionsFingerprint: String
        let textureMetadataPolicyFingerprint: String
        let colorFormat: String
        let depthFormat: String
        let hdr: Bool
    }

    /// Mutable frame history, video clocks, scripts, interaction, targets, and
    /// cancellation generation stay per renderer/display even for the same scene.
    private struct MutableSceneOwnerIdentity: Hashable {
        let screenID: UInt32
        let sceneID: String
        let generation: Int

        func reloaded() -> MutableSceneOwnerIdentity {
            MutableSceneOwnerIdentity(
                screenID: screenID,
                sceneID: sceneID,
                generation: generation + 1
            )
        }
    }

    private enum RendererOwnershipFixtureError: Error {
        case missingSourceBoundary(String)
    }
#endif
