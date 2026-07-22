import Foundation
@testable import LiveWallpaper
import Testing

struct WPESceneScriptContainmentCharacterizationTests {
    // MARK: - Current production boundaries (source only, zero JS execution)

    @Test("Production post-fix: four evaluators retain serial queues and use global admission")
    func productionEvaluatorsUseGlobalAdmission() throws {
        let runtime = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift"
        )

        for queueLabel in [
            "com.livewallpaper.wpe-scenescript",
            "com.livewallpaper.wpe-layerscript",
            "com.livewallpaper.wpe-transform-evaluator",
            "com.livewallpaper.wpe-dynamic-transform",
        ] {
            #expect(runtime.contains(queueLabel))
        }
        #expect(RR10ProductionSource.occurrences(
            of: "private let governor: WPESceneScriptExecutionGovernor",
            in: runtime
        ) >= 4)
        #expect(RR10ProductionSource.occurrences(
            of: "private let participant: WPESceneScriptExecutionGovernor.Participant",
            in: runtime
        ) >= 4)
        #expect(RR10ProductionSource.occurrences(
            of: "governor.tryAcquire(for: participant, in: traversalEpoch)",
            in: runtime
        ) >= 6)
        #expect(RR10ProductionSource.occurrences(
            of: "governor.tryAcquireUnreserved(for: participant)",
            in: runtime
        ) >= 7)
        #expect(RR10ProductionSource.occurrences(of: "governor.acquire(for: participant", in: runtime) >= 4)
        #expect(RR10ProductionSource.occurrences(
            of: "governor: WPESceneScriptExecutionGovernor = .processShared",
            in: runtime
        ) >= 4)
        #expect(RR10ProductionSource.occurrences(
            of: "asyncOutcomeSlot.rejectTick(claim)",
            in: runtime
        ) >= 3)
        #expect(runtime.contains("case capacityUnavailable(operation: WPESceneScriptOperation)"))
    }

    @Test("Production post-fix: renderer creates and forwards one explicit traversal epoch")
    func productionRendererForwardsOneTraversalEpoch() throws {
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let lifecycle = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
        )
        let renderer = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift"
        )

        #expect(RR10ProductionSource.occurrences(
            of: "WPESceneScriptTraversalEpoch.next(",
            in: frame
        ) == 1)
        #expect(frame.contains("domainID: sceneScriptTraversalDomainID"))
        #expect(frame.contains("processShared.completeTraversal("))
        #expect(frame.contains("if !needsContinuousFrames || currentProfile != .quality"))
        #expect(RR10ProductionSource.occurrences(
            of: "processShared.cancelReservations(",
            in: lifecycle
        ) >= 1)
        #expect(RR10ProductionSource.occurrences(
            of: "processShared.forgetDomain(",
            in: lifecycle
        ) >= 2)
        #expect(lifecycle.contains("case .suspended:"))
        #expect(renderer.contains("nonisolated var sceneScriptTraversalDomainID: UInt64"))
        #expect(renderer.contains("deinit {"))
        #expect(renderer.contains("processShared.forgetDomain("))
        #expect(RR10ProductionSource.occurrences(
            of: "traversalEpoch: scriptTraversalEpoch",
            in: frame
        ) == 3)
        #expect(RR10ProductionSource.occurrences(
            of: "traversalEpoch: traversalEpoch",
            in: frame
        ) >= 8)
    }

    @Test("Production post-fix: non-frame operations cannot fabricate traversal challenges")
    func productionNonFrameAdmissionStrategyIsExplicit() throws {
        let runtime = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift"
        )

        #expect(runtime.contains("admission: .failFast(traversalEpoch: nil)"))
        #expect(runtime.contains("guard let permit = governor.tryAcquireUnreserved(for: participant)"))
        #expect(RR10ProductionSource.occurrences(
            of: "admission: .waitUntilDeadline",
            in: runtime
        ) >= 4)
        #expect(runtime.contains("governor.acquire(for: participant, until: deadline)"))
    }

    @Test("Production B2b: frame watchdog quarantines async overrun without per-tick timers")
    func productionAsyncOverrunUsesSharedOwner() throws {
        let runtime = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift"
        )
        let resources = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptResourceBudget.swift"
        )

        #expect(RR10ProductionSource.occurrences(
            of: "engine.quarantineAsyncIfOverdue(budget: tickBudget)",
            in: runtime
        ) == 3)
        #expect(resources.contains("final class WPESceneScriptAsyncExecutionSafety"))
        #expect(resources.contains("watchdog probes this owner instead of allocating"))
        #expect(!resources.contains("asyncAfter"))
    }

    @Test("B2a production load captures and threads one exact token")
    func productionRendererThreadsExactLoadToken() throws {
        let renderer = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Text.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift",
        ])

        for seam in [
            "sceneScriptLoadState.begin(generation: generation)",
            "performLoad(scriptLoadToken: scriptLoadToken, on: actor)",
            "WPESceneScriptInstanceInventory(document: document)",
            "scriptLoadToken.prepare(scriptInventory)",
            "checkCurrentSceneScriptLoad(scriptLoadToken)",
            "sceneScriptLoadToken: scriptLoadToken",
            "constructSceneScript(for: scriptLoadToken",
            "sceneScriptLoadState.retire(scriptLoadToken)",
        ] {
            #expect(renderer.contains(seam))
        }
        let prepareRange = try #require(renderer.range(of: "scriptLoadToken.prepare(scriptInventory)"))
        let firstRuntimeRange = try #require(renderer.range(of: "try WPELayerScriptInstance("))
        #expect(prepareRange.lowerBound < firstRuntimeRange.lowerBound)
    }

    @Test("B2a reload cleanup and failed load clear every runtime family")
    func productionLifecycleClearsAllScriptRuntimeFamilies() throws {
        let load = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
        )
        let lifecycle = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
        )
        let seam = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift"
        )
        #expect(load.contains("if ownedFailedLoad { clearSceneScriptRuntimeState() }"))
        #expect(RR10ProductionSource.occurrences(of: "clearSceneScriptRuntimeState()", in: lifecycle) == 2)
        for dictionary in [
            "textScriptInstances", "layerScriptInstances", "layerAlphaScriptInstances",
            "textVisibleScriptInstances", "textAlphaScriptInstances",
            "dynamicOriginScriptInstances", "dynamicScaleScriptInstances",
            "dynamicAnglesScriptInstances", "liveLayerVisibility", "liveTextVisibility",
            "liveLayerAlpha", "liveTextAlpha", "liveCreatedLayers",
        ] {
            #expect(seam.contains("\(dictionary).removeAll(keepingCapacity: false)"))
        }
    }

    @Test("B2b load video commit requires its exact current completion token")
    func productionLoadCommitRequiresExactCurrentToken() throws {
        let load = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
        )
        let owner = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let finishAnchor = try #require(owner.range(of: "func finishSceneScriptLoadVideoCommands("))
        let prepareAnchor = try #require(owner.range(of: "func prepareSceneScriptsForFirstFrame("))
        let finishRegion = String(owner[finishAnchor.lowerBound ..< prepareAnchor.lowerBound])
        let prepareRegion = String(owner[prepareAnchor.lowerBound...])

        #expect(load.contains("var scriptsAreBaked = resetSceneScriptsToBakedIfFailed(scriptLoadToken)"))
        #expect(load.contains("try finishSceneScriptLoadVideoCommands("))
        #expect(load.contains("prepareSceneScriptsForFirstFrame("))
        #expect(load.contains("await shaderWarm"))
        let loadCommit = try #require(load.range(of: "try finishSceneScriptLoadVideoCommands("))
        let firstRender = try #require(load.range(of: "outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())"))
        let firstFrameRegion = String(load[loadCommit.lowerBound ..< firstRender.upperBound])
        let shaderAwait = try #require(firstFrameRegion.range(of: "await shaderWarm"))
        let currentCheck = try #require(
            firstFrameRegion.range(of: "try checkCurrentSceneScriptLoad(scriptLoadToken)")
        )
        let prepare = try #require(firstFrameRegion.range(of: "prepareSceneScriptsForFirstFrame("))
        let render = try #require(firstFrameRegion.range(of: "outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())"))
        #expect(shaderAwait.lowerBound < currentCheck.lowerBound)
        #expect(currentCheck.lowerBound < prepare.lowerBound)
        #expect(prepare.lowerBound < render.lowerBound)
        #expect(finishRegion.contains("finishSceneScriptVideoCommands(for: scriptLoadToken)"))
        #expect(finishRegion.contains("guard isCurrentSceneScriptLoad(scriptLoadToken),"))
        #expect(finishRegion.contains("scriptLoadToken.failureReason != nil,"))
        #expect(finishRegion.contains("resetSceneScriptsToBakedIfFailed(scriptLoadToken) else"))
        #expect(finishRegion.contains("throw CancellationError()"))
        #expect(prepareRegion.contains("resetSceneScriptsToBakedIfFailed(scriptLoadToken)"))
        #expect(RR10ProductionSource.occurrences(
            of: "resetSceneScriptsToBakedIfFailed(scriptLoadToken)",
            in: load + owner
        ) >= 3)
    }

    @Test("B2b player mutations and phase alignment share one linearized commit")
    func productionPlayerMutationIsLinearizedCommitOnly() throws {
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let scripts = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift"
        )
        let failClose = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let nonCommitSources = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift",
        ])

        #expect(frame.contains("stageIntroPhaseAlign()"))
        #expect(!frame.contains("updateIntroPhaseAlign()"))
        #expect(!scripts.contains("alignPlayhead"))
        for mutation in [
            ".scriptPlay()", ".scriptPause()", ".scriptStop()",
            ".scriptSetCurrentTime(seconds)", ".alignPlayhead(to: target)",
        ] {
            #expect(failClose.contains(mutation))
            #expect(!nonCommitSources.contains(mutation))
        }

        let authorization = try #require(failClose.range(of: "let committed = authorize {"))
        let rejection = try #require(failClose.range(of: "if !committed {"))
        let authorizedRegion = String(failClose[authorization.lowerBound ..< rejection.lowerBound])
        #expect(authorizedRegion.contains("sceneScriptVideoCommandBuffer.finish(commit: true)"))
        #expect(authorizedRegion.contains("video.scriptPlay()"))
        #expect(authorizedRegion.contains("updateIntroPhaseAlign()"))
        #expect(failClose.contains("sceneScriptLoadState.withCurrentCompletionPermission(commit)"))
        #expect(failClose.contains("sceneScriptLoadState.withCompletionPermission("))
        #expect(failClose.contains("for: scriptLoadToken"))
        #expect(failClose.contains("discardSceneScriptVideoCommands()"))
        #expect(RR10ProductionSource.occurrences(of: "updateIntroPhaseAlign()", in: failClose) == 2)
    }

    @Test("B2b Frame property and Load route through completion permission")
    func productionCommitPathsUseCompletionPermission() throws {
        let containment = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptContainment.swift"
        )
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let lifecycle = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
        )
        let load = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
        )
        let failClose = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )

        #expect(containment.contains("func withCompletionPermission("))
        #expect(containment.contains("func withCurrentCompletionPermission("))
        #expect(containment.contains("guard !state.isRetired, state.failureReason == nil"))
        #expect(containment.contains("guard current === token,"))
        #expect(containment.contains("return try token.withCompletionPermission(commit)"))
        #expect(frame.contains("return try finishSceneScriptFrame("))
        #expect(failClose.contains("if finishCurrentSceneScriptVideoCommands() {"))
        #expect(lifecycle.contains("&& finishCurrentSceneScriptVideoCommands()"))
        #expect(load.contains("try finishSceneScriptLoadVideoCommands("))
        #expect(failClose.contains("finishSceneScriptVideoCommands(for: scriptLoadToken)"))

        let rendererCommitSources = frame + lifecycle + load
        #expect(!rendererCommitSources.contains("finishSceneScriptVideoCommands(commit: true)"))
        #expect(!rendererCommitSources.contains("finishSceneScriptVideoCommands(commit: scriptsSucceeded)"))
        #expect(!rendererCommitSources.contains("commit: sceneScriptLoadState.currentFailureReason == nil"))
    }

    @Test("B2b denied frame commit rolls back and never returns its speculative frame")
    func failedFrameRollbackOracle() throws {
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let owner = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let encode = try #require(frame.range(of: "let frame = try encodeSceneFrame("))
        let finish = try #require(frame.range(of: "return try finishSceneScriptFrame("))
        let ownerAnchor = try #require(owner.range(of: "func finishSceneScriptFrame("))
        let ownerEnd = try #require(owner.range(of: "func updateParticleHostOriginOffsets("))
        let ownerRegion = String(owner[ownerAnchor.lowerBound ..< ownerEnd.lowerBound])
        let success = try #require(ownerRegion.range(of: "if finishCurrentSceneScriptVideoCommands() {"))
        let denial = try #require(ownerRegion.range(of: "invalidateIntroPhaseAlign()"))
        let denialRegion = String(ownerRegion[denial.lowerBound...])
        let rollback = try #require(denialRegion.range(of: "restoreSceneScriptPresentation(publicationBeforeFrame.presentation)"))
        let fallback = try #require(denialRegion.range(of: "let stableFrame = try encodeSceneFrame("))
        #expect(encode.lowerBound < finish.lowerBound)
        #expect(success.lowerBound < denial.lowerBound)
        #expect(rollback.lowerBound < fallback.lowerBound)
        #expect(frame.contains("discardSceneScriptVideoCommands()"))
        #expect(frame.contains("let publicationBeforeFrame = captureSceneScriptFramePublication()"))
        #expect(owner.contains("stableTransforms: lastStableScriptTransforms"))
        #expect(owner.contains("stableTextByID: lastStableScriptTextByID"))
        #expect(owner.contains("lastFramePipeline: lastFramePipeline"))
        #expect(denialRegion.contains("lastStableScriptTransforms = publicationBeforeFrame.stableTransforms"))
        #expect(denialRegion.contains("lastStableScriptTextByID = publicationBeforeFrame.stableTextByID"))
        #expect(denialRegion.contains("lastFramePipeline = publicationBeforeFrame.lastFramePipeline"))
        #expect(denialRegion.contains("guard let failure = sceneScriptLoadState.currentFailureReason else"))
        #expect(denialRegion.contains("throw CancellationError()"))
        #expect(denialRegion.contains("updateParticleHostOriginOffsets(using: stableTransforms)"))
        #expect(denialRegion.contains("return stableFrame"))
        #expect(!denialRegion.contains("return speculativeFrame"))

        let knownFailure = try #require(ownerRegion.range(of: "if failureBeforeFrame != nil {"))
        let commitStart = try #require(ownerRegion.range(of: "if finishCurrentSceneScriptVideoCommands() {"))
        let knownFailureRegion = String(ownerRegion[knownFailure.lowerBound ..< commitStart.lowerBound])
        #expect(knownFailureRegion.contains("discardSceneScriptVideoCommands()"))
        #expect(knownFailureRegion.contains("return speculativeFrame"))

        let particleTick = try #require(frame.range(of: "private func tickParticleSystems("))
        let particleTickRegion = String(frame[particleTick.lowerBound...])
        #expect(particleTickRegion.contains("updateParticleHostOriginOffsets(using: liveTransforms)"))
        #expect(!particleTickRegion.contains("system.hostOriginOffset = .zero"))
        #expect(owner.contains("system.hostOriginOffset = .zero"))
        #expect(owner.contains("system.hostOriginOffset += SIMD2<Float>("))

        var productionBuffer = WPESceneScriptVideoCommandBuffer()
        productionBuffer.begin()
        productionBuffer.enqueue([.seek(7.5)], objectID: "loop")
        #expect(productionBuffer.finish(commit: false).isEmpty)
        #expect(!productionBuffer.isTransactionActive)
        #expect(productionBuffer.pending.isEmpty)
    }

    @Test("B2b failed or retired setup invalidates phase measurement identity")
    func productionPhaseMeasurementCannotPublishAfterReset() throws {
        let phase = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let containment = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift"
        )
        let renderActorSource = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/RenderThread/WPEDisplayRenderActor.swift"
        )
        #expect(phase.contains("await actor.applyIntroLoopOffset(offset, token: token, scriptLoadToken: scriptLoadToken)"))
        #expect(renderActorSource.contains("renderer.introPhaseToken == token"))
        #expect(renderActorSource.contains("renderer.isCurrentSceneScriptLoad(scriptLoadToken)"))
        #expect(phase.contains("introPhaseToken &+= 1"))
        #expect(containment.contains("invalidateIntroPhaseAlign()"))
    }

    @Test("B2b failure before completion permission produces zero side effects")
    func failureBeforeCompletionPermissionRejectsCommit() {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 401)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        #expect(token.failClosed(.executionTimedOut(operation: .tick)))
        var sideEffects = 0

        #expect(!state.withCurrentCompletionPermission { sideEffects += 1 })
        #expect(!state.withCompletionPermission(for: token) { sideEffects += 1 })
        #expect(sideEffects == 0)
    }

    @Test("B2b completion holding permission linearizes before concurrent fail-close")
    func completionPermissionLinearizesConcurrentFailure() throws {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 402)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        let commitBlocker = RR10ControlledBlocker()
        let queue = DispatchQueue(
            label: "com.livewallpaper.tests.rr10-completion-linearization",
            attributes: .concurrent
        )
        let commitAccepted = RR10LockedValue<Bool?>(nil)
        let failureAccepted = RR10LockedValue<Bool?>(nil)
        let sideEffects = RR10LockedValue(0)
        let order = RR10LockedValue<[String]>([])
        let failureStarted = DispatchSemaphore(value: 0)
        let failureFinished = DispatchGroup()
        failureFinished.enter()
        defer { commitBlocker.release() }

        queue.async {
            let accepted = state.withCompletionPermission(for: token) {
                commitBlocker.run()
                sideEffects.modify { $0 += 1 }
                order.modify { $0.append("commit") }
            }
            commitAccepted.set(accepted)
            commitBlocker.markFinished()
        }
        try #require(commitBlocker.waitUntilEntered())

        let reason = WPESceneScriptFailClosedReason.executionTimedOut(operation: .tick)
        queue.async {
            failureStarted.signal()
            failureAccepted.set(token.failClosed(reason))
            order.modify { $0.append("fail") }
            failureFinished.leave()
        }
        try #require(failureStarted.wait(timeout: .now() + 2) == .success)
        commitBlocker.release()
        try #require(commitBlocker.waitUntilFinished())
        try #require(failureFinished.wait(timeout: .now() + 2) == .success)

        #expect(commitAccepted.value == true)
        #expect(failureAccepted.value == true)
        #expect(sideEffects.value == 1)
        #expect(order.value == ["commit", "fail"])
        #expect(token.failureReason == reason)
        #expect(!commitBlocker.hitHardDeadline)
    }

    @Test("B2b retired and superseded identities receive zero completion effects")
    func retiredAndSupersededCompletionIsRejected() {
        let state = WPESceneScriptLoadState()
        let old = state.begin(generation: 403)
        #expect(old.prepare(.init(text: 0, layer: 1, transform: 0)))
        let replacement = state.begin(generation: 404)
        #expect(replacement.prepare(.init(text: 0, layer: 1, transform: 0)))
        var sideEffects = 0

        #expect(!state.withCompletionPermission(for: old) { sideEffects += 1 })
        state.retire(replacement)
        #expect(!state.withCompletionPermission(for: replacement) { sideEffects += 1 })
        #expect(!state.withCurrentCompletionPermission { sideEffects += 1 })
        #expect(sideEffects == 0)
    }

    @Test("Production post-fix: late async completions use the scene publish gate")
    func productionLateCompletionGateIsWiredAcrossRuntimeFamilies() throws {
        let runtime = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift"
        )

        #expect(RR10ProductionSource.occurrences(
            of: "guard self.acceptsCompletion() else",
            in: runtime
        ) >= 4)
        #expect(RR10ProductionSource.occurrences(
            of: "slot.rejectTick(claim)",
            in: runtime
        ) >= 3)
    }

    // MARK: - Production primitive behavior

    @Test("Containment defaults are conservative and explicitly policy-bound")
    func containmentDefaultsAreConservative() {
        #expect((1 ... 8).contains(WPESceneScriptContainmentDefaults.maximumConcurrentEvaluations))
        #expect(WPESceneScriptContainmentDefaults.maximumScriptInstancesPerScene <= 256)
        #expect(WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene <= 128)
        #expect(WPESceneScriptContainmentDefaults.maximumVideoCommandsPerEvaluation <= 512)
        #expect(WPESceneScriptContainmentDefaults.maximumSharedStateEntries <= 2048)
        #expect(WPESceneScriptContainmentDefaults.maximumQuarantinedEngines <= 32)
        #expect(WPESceneScriptContainmentDefaults.frameCapacityRejectionPolicy == .keepLastCompleted)
        #expect(WPESceneScriptContainmentDefaults.setupCapacityRejectionPolicy == .failSceneClosed)
    }

    @Test("B2a exact 128 constructs all while 129 constructs none")
    func sceneRuntimeInventoryExactLimitAndLimitPlusOne() throws {
        let state = WPESceneScriptLoadState()
        let exact = WPESceneScriptInstanceInventory(text: 41, layer: 43, transform: 44)
        let accepted = state.begin(generation: 1)
        #expect(accepted.prepare(exact))
        var exactAttempts = 0
        for _ in 0 ..< exact.total {
            _ = try #require(accepted.withConstructionPermission { exactAttempts += 1 })
        }
        #expect(exactAttempts == 128)

        let over = WPESceneScriptInstanceInventory(text: 42, layer: 43, transform: 44)
        let rejected = state.begin(generation: 2)
        #expect(!rejected.prepare(over))
        #expect(state.isCurrent(rejected))
        #expect(!rejected.acceptsCompletion())
        var rejectedAttempts = 0
        for _ in 0 ..< over.total {
            _ = rejected.withConstructionPermission { rejectedAttempts += 1 }
        }
        #expect(rejectedAttempts == 0)
    }

    @Test("Retired interleaved load cannot prepare construct or publish into fresh load")
    func sceneRuntimeLateCompletionAndLifecycleReset() throws {
        let state = WPESceneScriptLoadState()
        let old = state.begin(generation: 1)
        #expect(old.prepare(.init(text: 1, layer: 0, transform: 0)))
        let fresh = state.begin(generation: 2)
        #expect(!state.isCurrent(old))
        #expect(!old.prepare(.init(text: 0, layer: 1, transform: 0)))
        var oldAttempts = 0
        _ = old.withConstructionPermission { oldAttempts += 1 }
        #expect(oldAttempts == 0)
        let slot = WPESceneScriptClaimedOutcomeSlot<String>()
        let claim = try #require(slot.beginClaim())
        if old.acceptsCompletion() {
            _ = slot.publish("late", for: claim)
        } else {
            #expect(slot.reject(claim))
        }
        #expect(slot.takeLatest() == nil)
        #expect(fresh.prepare(.init(text: 0, layer: 0, transform: 1)))
        #expect(state.isCurrent(fresh))
        state.retire(fresh)
        #expect(!state.isCurrent(fresh))
        #expect(!fresh.acceptsCompletion())
    }

    @Test("Permit release is idempotent and deinit is a fail-safe")
    func permitLifetimeIsSafe() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let participant = governor.makeParticipant()
        let explicit = try #require(governor.tryAcquireUnreserved(for: participant))
        #expect(governor.tryAcquireUnreserved(for: participant) == nil)

        explicit.release()
        explicit.release()
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif

        var failSafe: WPESceneScriptExecutionGovernor.Permit?
        do {
            let acquired = try #require(
                governor.tryAcquireUnreserved(for: participant)
            )
            failSafe = acquired
        }
        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif
        failSafe = nil
        #expect(failSafe == nil)
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif
    }

    @Test("Global governor holds N permits until workers really return")
    func globalGovernorBoundsWorkers() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 2
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.limit-two",
                attributes: .concurrent
            )
        )
        let first = RR10ControlledBlocker()
        let second = RR10ControlledBlocker()
        let third = RR10ControlledBlocker()
        let firstParticipant = governor.makeParticipant()
        let secondParticipant = governor.makeParticipant()
        let thirdParticipant = governor.makeParticipant()
        var firstStarted = false
        var secondStarted = false
        var thirdStarted = false
        defer {
            first.release()
            second.release()
            third.release()
            if firstStarted {
                _ = first.waitUntilFinished()
            }
            if secondStarted {
                _ = second.waitUntilFinished()
            }
            if thirdStarted {
                _ = third.waitUntilFinished()
            }
        }

        firstStarted = harness.trySchedule(
            first.run,
            participant: firstParticipant,
            onFinish: first.markFinished
        )
        secondStarted = harness.trySchedule(
            second.run,
            participant: secondParticipant,
            onFinish: second.markFinished
        )
        #expect(firstStarted)
        #expect(secondStarted)
        try #require(first.waitUntilEntered())
        try #require(second.waitUntilEntered())

        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 2,
                waitingParticipants: 0
            ))
        #endif
        let thirdAdmittedWhileFull = harness.trySchedule(
            {},
            participant: thirdParticipant,
            onFinish: {}
        )
        #expect(!thirdAdmittedWhileFull)
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 2,
                waitingParticipants: 0
            ))
        #endif
        #expect(harness.workersStarted == 2)

        first.release()
        try #require(first.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif

        thirdStarted = harness.trySchedule(
            third.run,
            participant: thirdParticipant,
            onFinish: third.markFinished
        )
        #expect(thirdStarted)
        try #require(third.waitUntilEntered())
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 3,
                waitingParticipants: 0
            ))
        #endif

        second.release()
        third.release()
        try #require(second.waitUntilFinished())
        try #require(third.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 0,
                peak: 2,
                permitsGranted: 3,
                waitingParticipants: 0
            ))
        #endif
        #expect(harness.workersStarted == 3)
        #expect(!first.hitHardDeadline)
        #expect(!second.hitHardDeadline)
        #expect(!third.hitHardDeadline)
    }

    @Test("Frame FIFO fairness is cadence-independent and never waits")
    func frameFairnessDoesNotDependOnFrameRate() throws {
        let source = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptContainment.swift"
        )
        #expect(!source.contains("opportunisticReservationLifetime"))
        #expect(source.contains("struct WPESceneScriptTraversalEpoch"))
        #expect(source.contains("func completeTraversal("))
        #expect(source.contains("func cancelReservations(domainID:"))
        #expect(source.contains("func forgetDomain(domainID:"))
        #expect(source.contains("epoch.generation > completed"))
        #expect(!source.contains("traversalDomainByParticipantID.compactMap"))
        #expect(!source.contains("traversalDomainByParticipantID.values.contains"))
        #expect(source.contains("participantIDsByTraversalDomain"))
        #expect(source.contains("bounded waiter queue (maximum 256)"))

        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let fixedPrefix = governor.makeParticipant()
        let rejectedTail = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        let saturatedEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_001)

        #expect(governor.tryAcquire(for: rejectedTail, in: saturatedEpoch) == nil)
        heldPermit.release()

        let recoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_001)
        #expect(governor.tryAcquire(for: fixedPrefix, in: recoveryEpoch) == nil)
        for _ in 0 ..< 32 {
            #expect(governor.tryAcquire(for: fixedPrefix, in: recoveryEpoch) == nil)
        }
        let tailPermit = try #require(
            governor.tryAcquire(for: rejectedTail, in: recoveryEpoch)
        )
        tailPermit.release()

        let prefixPermit = try #require(
            governor.tryAcquire(for: fixedPrefix, in: recoveryEpoch)
        )
        prefixPermit.release()
    }

    @Test("Traversal completion removes only reservations not renewed by that domain")
    func abandonedFrameReservationCannotWedgeAdmission() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let abandoned = governor.makeParticipant()
        let continuing = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        let saturatedEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_002)
        #expect(governor.tryAcquire(for: abandoned, in: saturatedEpoch) == nil)
        #expect(governor.tryAcquire(for: continuing, in: saturatedEpoch) == nil)
        governor.completeTraversal(saturatedEpoch)

        let firstRecoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_002)
        #expect(governor.tryAcquire(for: continuing, in: firstRecoveryEpoch) == nil)
        governor.completeTraversal(firstRecoveryEpoch)
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 1)
        #endif

        heldPermit.release()
        let nextRecoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_002)
        let continuingPermit = try #require(
            governor.tryAcquire(for: continuing, in: nextRecoveryEpoch)
        )
        continuingPermit.release()
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Limit greater than one preserves fairness across renderer domains")
    func multiDomainLimitDoesNotLetHotRendererEvictSlowRenderer() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 2)
        let firstHolder = governor.makeParticipant()
        let secondHolder = governor.makeParticipant()
        let firstSlowRenderer = governor.makeParticipant()
        let secondSlowRenderer = governor.makeParticipant()
        let hotRenderer = governor.makeParticipant()
        let firstHeld = try #require(governor.tryAcquireUnreserved(for: firstHolder))
        let secondHeld = try #require(governor.tryAcquireUnreserved(for: secondHolder))
        defer {
            firstHeld.release()
            secondHeld.release()
        }
        let slowDomain: UInt64 = 20_001
        let slowEpoch = WPESceneScriptTraversalEpoch.next(domainID: slowDomain)
        let hotEpoch = WPESceneScriptTraversalEpoch.next(domainID: 20_002)
        #expect(governor.tryAcquire(for: firstSlowRenderer, in: slowEpoch) == nil)
        #expect(governor.tryAcquire(for: secondSlowRenderer, in: slowEpoch) == nil)
        #expect(governor.tryAcquire(for: hotRenderer, in: hotEpoch) == nil)

        firstHeld.release()
        for _ in 0 ..< 64 {
            #expect(governor.tryAcquire(for: hotRenderer, in: hotEpoch) == nil)
        }
        governor.cancelReservations(domainID: slowDomain)
        let hotPermit = try #require(
            governor.tryAcquire(for: hotRenderer, in: hotEpoch)
        )
        hotPermit.release()
    }

    @Test("Heavy renderer flooding the queue first cannot starve a light renderer")
    func heavyDomainCannotStarveLightDomainAcrossFrames() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 4)
        let heavy = (0 ..< 12).map { _ in governor.makeParticipant() }
        let light = governor.makeParticipant()
        let heavyDomain: UInt64 = 30_001
        let lightDomain: UInt64 = 30_002

        var lightServedFrame: Int?
        for frame in 0 ..< 8 {
            let heavyEpoch = WPESceneScriptTraversalEpoch.next(domainID: heavyDomain)
            let lightEpoch = WPESceneScriptTraversalEpoch.next(domainID: lightDomain)
            var held: [WPESceneScriptExecutionGovernor.Permit] = []
            for participant in heavy {
                if let permit = governor.tryAcquire(for: participant, in: heavyEpoch) {
                    held.append(permit)
                }
            }
            if let permit = governor.tryAcquire(for: light, in: lightEpoch) {
                if lightServedFrame == nil { lightServedFrame = frame }
                permit.release()
            }
            governor.completeTraversal(heavyEpoch)
            governor.completeTraversal(lightEpoch)
            for permit in held { permit.release() }
        }
        let served = try #require(lightServedFrame, "light renderer was starved for 8 frames")
        #expect(served <= 2)
    }

    @Test("Out-of-order and completed epochs cannot roll participant liveness back")
    func oldTraversalEpochIsIgnored() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let reserved = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        defer { heldPermit.release() }
        let oldEpoch = WPESceneScriptTraversalEpoch.next(domainID: 20_003)
        let currentEpoch = WPESceneScriptTraversalEpoch.next(domainID: 20_003)
        #expect(governor.tryAcquire(for: reserved, in: currentEpoch) == nil)

        #expect(governor.tryAcquire(for: reserved, in: oldEpoch) == nil)
        governor.completeTraversal(oldEpoch)
        governor.completeTraversal(currentEpoch)
        governor.completeTraversal(currentEpoch)
        #expect(governor.tryAcquire(for: reserved, in: currentEpoch) == nil)
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 1)
        #endif

        heldPermit.release()
        let recoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 20_003)
        let recovered = try #require(
            governor.tryAcquire(for: reserved, in: recoveryEpoch)
        )
        recovered.release()
    }

    @Test("Static no-next-frame completion cancels only its renderer domain")
    func staticRendererCancellationUnwedgesOtherDomain() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let staticRenderer = governor.makeParticipant()
        let continuousRenderer = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        let staticDomain: UInt64 = 20_004
        let continuousDomain: UInt64 = 20_005
        let staticEpoch = WPESceneScriptTraversalEpoch.next(domainID: staticDomain)
        let continuousEpoch = WPESceneScriptTraversalEpoch.next(domainID: continuousDomain)
        #expect(governor.tryAcquire(for: staticRenderer, in: staticEpoch) == nil)
        #expect(governor.tryAcquire(for: continuousRenderer, in: continuousEpoch) == nil)

        governor.completeTraversal(staticEpoch)
        governor.cancelReservations(domainID: staticDomain)
        heldPermit.release()
        let continuousPermit = try #require(
            governor.tryAcquire(for: continuousRenderer, in: continuousEpoch)
        )
        continuousPermit.release()
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Suspending a renderer cancels its reservations without touching blocking work")
    func suspendCancellationIsDomainScoped() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let suspended = governor.makeParticipant()
        let other = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        defer { heldPermit.release() }
        let suspendedDomain: UInt64 = 20_006
        let otherDomain: UInt64 = 20_007
        let suspendedEpoch = WPESceneScriptTraversalEpoch.next(domainID: suspendedDomain)
        let otherEpoch = WPESceneScriptTraversalEpoch.next(domainID: otherDomain)
        #expect(governor.tryAcquire(for: suspended, in: suspendedEpoch) == nil)
        #expect(governor.tryAcquire(for: other, in: otherEpoch) == nil)

        governor.cancelReservations(domainID: suspendedDomain)
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 1)
        #endif
        governor.cancelReservations(domainID: otherDomain)
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Async worker keeps its permit while same-epoch frame probes stay fair")
    func asyncWorkerRetainsPermitAcrossFrameProbes() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(label: "com.livewallpaper.tests.rr10-governor.worker-fairness")
        )
        let blocker = RR10ControlledBlocker()
        let worker = governor.makeParticipant()
        let rejectedTail = governor.makeParticipant()
        let hotPrefix = governor.makeParticipant()
        var workerStarted = false
        defer {
            blocker.release()
            if workerStarted {
                _ = blocker.waitUntilFinished()
            }
        }

        workerStarted = harness.trySchedule(
            blocker.run,
            participant: worker,
            onFinish: blocker.markFinished
        )
        #expect(workerStarted)
        try #require(blocker.waitUntilEntered())

        let saturatedEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_003)
        #expect(governor.tryAcquire(for: rejectedTail, in: saturatedEpoch) == nil)
        for _ in 0 ..< 16 {
            #expect(governor.tryAcquire(for: hotPrefix, in: saturatedEpoch) == nil)
        }
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 1,
                peak: 1,
                permitsGranted: 1,
                waitingParticipants: 2
            ))
        #endif
        #expect(harness.workersStarted == 1)

        blocker.release()
        try #require(blocker.waitUntilFinished())
        let recoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 10_003)
        for _ in 0 ..< 16 {
            #expect(governor.tryAcquire(for: hotPrefix, in: recoveryEpoch) == nil)
        }
        let tailPermit = try #require(
            governor.tryAcquire(for: rejectedTail, in: recoveryEpoch)
        )
        tailPermit.release()
        let prefixPermit = try #require(
            governor.tryAcquire(for: hotPrefix, in: recoveryEpoch)
        )
        prefixPermit.release()
        #expect(!blocker.hitHardDeadline)
    }

    @Test("Participant deinit cancels its frame reservation")
    func participantDeinitClearsReservation() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        defer { heldPermit.release() }
        let epoch = WPESceneScriptTraversalEpoch.next(domainID: 10_004)

        do {
            let reserved = governor.makeParticipant()
            #expect(governor.tryAcquire(for: reserved, in: epoch) == nil)
            #if DEBUG
                #expect(governor.debugSnapshot.waitingParticipants == 1)
                #expect(governor.debugTrackedTraversalDomainCount == 1)
            #endif
        }

        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
            #expect(governor.debugTrackedTraversalDomainCount == 0)
        #endif
    }

    @Test("Empty renderer domain bookkeeping is reclaimed on lifecycle cancel")
    func emptyDomainBookkeepingIsReclaimed() {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let domainID: UInt64 = 10_044
        let epoch = WPESceneScriptTraversalEpoch.next(domainID: domainID)
        governor.completeTraversal(epoch)
        #if DEBUG
            #expect(governor.debugTrackedTraversalDomainCount == 1)
        #endif
        governor.cancelReservations(domainID: domainID)
        #if DEBUG
            #expect(governor.debugTrackedTraversalDomainCount == 0)
        #endif
    }

    @Test("Forgotten domain unbinds quarantined participants and permits a fresh bind")
    func forgottenDomainReclaimsQuarantineBookkeeping() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        defer { heldPermit.release() }
        var quarantined: WPESceneScriptExecutionGovernor.Participant? = governor.makeParticipant()
        let retiredDomain: UInt64 = 10_045
        let retiredEpoch = WPESceneScriptTraversalEpoch.next(domainID: retiredDomain)
        do {
            let participant = try #require(quarantined)
            #expect(governor.tryAcquire(for: participant, in: retiredEpoch) == nil)
        }
        #if DEBUG
            #expect(governor.debugBoundTraversalParticipantCount == 1)
            #expect(governor.debugTrackedTraversalDomainCount == 1)
        #endif

        governor.forgetDomain(domainID: retiredDomain)
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
            #expect(governor.debugBoundTraversalParticipantCount == 0)
            #expect(governor.debugTrackedTraversalDomainCount == 0)
        #endif

        let freshDomain: UInt64 = 10_046
        let freshEpoch = WPESceneScriptTraversalEpoch.next(domainID: freshDomain)
        do {
            let participant = try #require(quarantined)
            #expect(governor.tryAcquire(for: participant, in: freshEpoch) == nil)
        }
        #if DEBUG
            #expect(governor.debugBoundTraversalParticipantCount == 1)
            #expect(governor.debugTrackedTraversalDomainCount == 1)
        #endif
        governor.forgetDomain(domainID: freshDomain)
        quarantined = nil
        #if DEBUG
            #expect(governor.debugBoundTraversalParticipantCount == 0)
            #expect(governor.debugTrackedTraversalDomainCount == 0)
        #endif
    }

    @Test("Frame reservation queue enforces its participant bound")
    func maximumWaitingParticipantsIsEnforced() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 1,
            maximumWaitingParticipants: 2
        )
        let holder = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        defer { heldPermit.release() }
        let epoch = WPESceneScriptTraversalEpoch.next(domainID: 10_005)

        do {
            let first = governor.makeParticipant()
            let second = governor.makeParticipant()
            let rejected = governor.makeParticipant()
            #expect(governor.tryAcquire(for: first, in: epoch) == nil)
            #expect(governor.tryAcquire(for: second, in: epoch) == nil)
            #expect(governor.tryAcquire(for: rejected, in: epoch) == nil)
            #if DEBUG
                #expect(governor.debugSnapshot.waitingParticipants == 2)
            #endif
        }

        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Blocking deadline removes opportunistic and blocking waiters")
    func mixedAdmissionDeadlineLeavesNoOrphan() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let opportunistic = governor.makeParticipant()
        let blocking = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))
        let epoch = WPESceneScriptTraversalEpoch.next(domainID: 10_006)
        #expect(governor.tryAcquire(for: opportunistic, in: epoch) == nil)

        #expect(governor.acquire(for: blocking, until: .now() + 0.01) == nil)
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 1,
                peak: 1,
                permitsGranted: 1,
                waitingParticipants: 0
            ))
        #endif

        heldPermit.release()
        let recovered = try #require(governor.tryAcquireUnreserved(for: blocking))
        recovered.release()
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Scene timeout fails closed while its running permit remains occupied")
    func timeoutFailsClosedWithoutReleasingRunningPermit() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 1
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.scene-timeout",
                attributes: .concurrent
            )
        )
        let blocker = RR10ControlledBlocker()
        let scene = WPESceneScriptFailClosedState(baked: "baked")
        let workerParticipant = governor.makeParticipant()
        let rejectedParticipant = governor.makeParticipant()
        let latePublishAccepted = RR10LockedValue<Bool?>(nil)
        var started = false
        defer {
            blocker.release()
            if started {
                _ = blocker.waitUntilFinished()
            }
        }

        started = harness.trySchedule({
            blocker.run()
            latePublishAccepted.set(scene.publishCompleted("late-worker-result"))
        }, participant: workerParticipant, onFinish: blocker.markFinished)
        #expect(started)
        try #require(blocker.waitUntilEntered())
        #expect(scene.publishCompleted("last-completed"))
        let firstReason = WPESceneScriptFailClosedReason.executionTimedOut(operation: .tick)
        #expect(scene.failClosed(firstReason))
        #expect(!scene.failClosed(.capacityUnavailable(operation: .event)))
        #expect(scene.failureReason == firstReason)

        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif
        let rejectedAdmitted = harness.trySchedule(
            {},
            participant: rejectedParticipant,
            onFinish: {}
        )
        #expect(!rejectedAdmitted)
        for operation in WPESceneScriptOperation.allCases {
            #expect(!scene.allows(operation))
        }

        blocker.release()
        try #require(blocker.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif
        #expect(scene.presentedSnapshot == "last-completed")
        #expect(latePublishAccepted.value == false)
        #expect(!blocker.hitHardDeadline)
    }

    @Test("Fail-closed scene preserves baked value when nothing completed")
    func failClosedPreservesBakedValue() {
        let scene = WPESceneScriptFailClosedState(baked: "baked")
        let reason = WPESceneScriptFailClosedReason.capacityUnavailable(operation: .setup)
        #expect(scene.failClosed(reason))

        #expect(scene.presentedSnapshot == "baked")
        #expect(scene.failureReason == reason)
        for operation in WPESceneScriptOperation.allCases {
            #expect(!scene.allows(operation))
        }
    }

    @Test("Rejected async scheduling returns the in-flight slot without publishing")
    func rejectedAsyncSchedulingReturnsSlot() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 1
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.outcome-slot",
                attributes: .concurrent
            )
        )
        let occupyingWorker = RR10ControlledBlocker()
        let occupyingParticipant = governor.makeParticipant()
        let rejectedParticipant = governor.makeParticipant()
        let slot = WPESceneScriptClaimedOutcomeSlot<String>()
        var occupyingWorkerStarted = false
        defer {
            occupyingWorker.release()
            if occupyingWorkerStarted {
                _ = occupyingWorker.waitUntilFinished()
            }
        }

        occupyingWorkerStarted = harness.trySchedule(
            occupyingWorker.run,
            participant: occupyingParticipant,
            onFinish: occupyingWorker.markFinished
        )
        #expect(occupyingWorkerStarted)
        try #require(occupyingWorker.waitUntilEntered())

        let rejectedClaim = try #require(slot.beginClaim())
        let scheduled = harness.trySchedule({
            slot.publish("must-not-run", for: rejectedClaim)
        }, participant: rejectedParticipant, onFinish: {})
        #expect(!scheduled)
        #expect(slot.reject(rejectedClaim))
        #expect(!slot.publish("late-rejected-result", for: rejectedClaim))

        #expect(!slot.isInFlight)
        #expect(slot.takeLatest() == nil)
        let freshClaim = try #require(slot.beginClaim())
        #expect(freshClaim != rejectedClaim)
        #expect(!slot.reject(rejectedClaim))
        #expect(slot.isInFlight)
        #expect(!slot.publish("late-rejected-result", for: rejectedClaim))
        #expect(slot.isInFlight)
        #expect(slot.publish("fresh-result", for: freshClaim))
        #expect(slot.takeLatest() == "fresh-result")

        occupyingWorker.release()
        try #require(occupyingWorker.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.permitsGranted == 1)
        #endif
        #expect(harness.workersStarted == 1)
        #expect(!occupyingWorker.hitHardDeadline)
    }
}

private final class RR10PermitWorkerHarness: @unchecked Sendable {
    private let governor: WPESceneScriptExecutionGovernor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = 0

    init(governor: WPESceneScriptExecutionGovernor, queue: DispatchQueue) {
        self.governor = governor
        self.queue = queue
    }

    var workersStarted: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func trySchedule(
        _ work: @escaping @Sendable () -> Void,
        participant: WPESceneScriptExecutionGovernor.Participant,
        onFinish: @escaping @Sendable () -> Void
    ) -> Bool {
        guard let permit = governor.tryAcquireUnreserved(for: participant) else { return false }
        lock.lock()
        started += 1
        lock.unlock()
        queue.async {
            defer {
                permit.release()
                onFinish()
            }
            _ = participant
            work()
        }
        return true
    }
}

private final class RR10ControlledBlocker: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var released = false
    private var didHitHardDeadline = false

    init() {
        completion.enter()
    }

    var hitHardDeadline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didHitHardDeadline
    }

    func run() {
        entered.signal()
        guard releaseSemaphore.wait(timeout: .now() + 2) == .success else {
            lock.lock()
            didHitHardDeadline = true
            lock.unlock()
            return
        }
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }

    func markFinished() {
        completion.leave()
    }

    func waitUntilFinished() -> Bool {
        completion.wait(timeout: .now() + 2) == .success
    }
}

private final class RR10LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func modify(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

private enum RR10ProductionSource {
    static func read(_ repositoryRelativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(repositoryRelativePath),
            encoding: .utf8
        )
    }

    static func combined(_ repositoryRelativePaths: [String]) throws -> String {
        try repositoryRelativePaths.map(read).joined(separator: "\n")
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
