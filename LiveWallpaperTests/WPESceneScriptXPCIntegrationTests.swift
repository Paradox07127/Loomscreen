import Foundation
import LiveWallpaperProWPE
@testable import LiveWallpaper
import Testing

@Suite(.serialized)
struct WPESceneScriptXPCIntegrationTests {
    private static let originScript = """
    'use strict';
    export var scriptProperties = createScriptProperties()
        .addSlider({name: 'x', value: 0.5})
        .addSlider({name: 'y', value: 0.5})
        .finish();
    export function update(value) {
        value.x = scriptProperties.x * engine.canvasSize.x;
        value.y = scriptProperties.y * engine.canvasSize.y;
        return value;
    }
    """

    @Test("Embedded worker evaluates one ordered document batch")
    func evaluatesBatch() throws {
        let client = WPESceneScriptXPCClient.shared
        #expect(client.isEmbeddedServiceAvailable)

        let result = client.evaluateStaticTransforms(
            canvasWidth: 1_000,
            canvasHeight: 800,
            requests: [
                .init(
                    script: Self.originScript,
                    properties: ["x": .number(0.25), "y": .number(0.75)],
                    seed: .init(1, 2, 3)
                ),
                .init(
                    script: Self.originScript,
                    properties: [:],
                    seed: .init(4, 5, 6)
                )
            ],
            evaluationBudget: 0.5
        )
        guard case .completed(let completion) = result else {
            Issue.record("Expected XPC completion, got \(result)")
            return
        }
        #expect(completion.values == [
            SIMD3<Double>(250, 600, 3),
            SIMD3<Double>(500, 400, 6)
        ])
        #expect(completion.workerPID > 0)
        #expect(completion.durationNanoseconds > 0)
    }

    @Test("Hard deadline kills only the worker and launchd restarts it")
    func hardDeadlineRestartsWorker() throws {
        let client = WPESceneScriptXPCClient.shared
        let before = try Self.requireCompletion(Self.benignRequest(client))

        // Comment trivia bypasses the conservative textual loop prefilter while
        // remaining a real JavaScript loop. Only the XPC watchdog may execute it.
        let hostile = """
        export function update(value) {
            while/* hostile watchdog probe */(true) {}
            return value;
        }
        """
        let started = ContinuousClock.now
        let hostileResult = client.evaluateStaticTransforms(
            canvasWidth: 1,
            canvasHeight: 1,
            requests: [.init(script: hostile, properties: [:], seed: .zero)],
            evaluationBudget: 0.05
        )
        #expect(hostileResult == .transportFailure)
        #expect(started.duration(to: .now) < .seconds(2))

        // launchd keeps the crashed embedded service stub semi-active for a
        // short grace period before it can instantiate a fresh process. Probe
        // with fail-fast requests so the host remains responsive throughout.
        let after = try Self.waitForRestart(client, timeout: .seconds(14))
        #expect(after.values == [SIMD3<Double>(5, 6, 7)])
        #expect(after.workerInstanceID != before.workerInstanceID)
        #expect(after.workerPID != before.workerPID)
    }

    @Test("Distinct document batches reuse the process-scoped worker")
    func distinctBatchesReuseProcessWorker() throws {
        let client = WPESceneScriptXPCClient.shared
        let first = try Self.requireCompletion(Self.benignRequest(client))
        let second = try Self.requireCompletion(client.evaluateStaticTransforms(
            canvasWidth: 200,
            canvasHeight: 100,
            requests: [
                .init(
                    script: "export function update(value) { value.x = 99; return value; }",
                    properties: [:],
                    seed: .init(1, 2, 3)
                )
            ],
            evaluationBudget: 0.5
        ))

        #expect(second.values == [SIMD3<Double>(99, 2, 3)])
        #expect(second.workerInstanceID == first.workerInstanceID)
        #expect(second.workerPID == first.workerPID)
    }

    @Test("Oversized batch is rejected without replacing the process worker")
    func rejectsOversizedBatch() throws {
        let client = WPESceneScriptXPCClient.shared
        let before = try Self.requireCompletion(Self.benignRequest(client))
        let item = WPESceneTransformScriptRequest(
            script: "export function update(value) { return value; }",
            properties: [:],
            seed: .zero
        )
        let result = client.evaluateStaticTransforms(
            canvasWidth: 1,
            canvasHeight: 1,
            requests: Array(repeating: item, count: 257),
            evaluationBudget: 0.5
        )
        #expect(result == .rejected(.resourceLimitExceeded))
        let after = try Self.requireCompletion(Self.benignRequest(client))
        #expect(after.workerInstanceID == before.workerInstanceID)
        #expect(after.workerPID == before.workerPID)
    }

#if DEBUG && !LITE_BUILD
    @Test("Opt-in client diagnostics retain only completion metadata")
    func recordsOptInCompletionDiagnostics() throws {
        let wasEnabled = WPESceneScriptXPCDiagnostics.isEnabled
        WPESceneScriptXPCDiagnostics.setEnabled(true)
        WPESceneScriptXPCDiagnostics.reset()
        defer {
            WPESceneScriptXPCDiagnostics.reset()
            WPESceneScriptXPCDiagnostics.setEnabled(wasEnabled)
        }

        let completion = try Self.requireCompletion(Self.benignRequest(WPESceneScriptXPCClient.shared))
        let snapshot = WPESceneScriptXPCDiagnostics.snapshot()
        let attempt = try #require(snapshot.attempts.last)

        #expect(snapshot.isEnabled)
        #expect(attempt.outcome == .completed)
        #expect(attempt.workerInstanceID == completion.workerInstanceID)
        #expect(attempt.workerPID == completion.workerPID)
        #expect(attempt.measurements.workerReportedNanoseconds == completion.durationNanoseconds)
        #expect(attempt.measurements.replyWaitNanoseconds > 0)
        #expect(snapshot.counters.completedAttempts == 1)
        #expect(snapshot.counters.currentInFlightAttempts == 0)
    }
#endif

    private static func benignRequest(
        _ client: WPESceneScriptXPCClient,
        evaluationBudget: TimeInterval = 0.5
    ) -> WPESceneScriptXPCClientResult {
        client.evaluateStaticTransforms(
            canvasWidth: 1,
            canvasHeight: 1,
            requests: [
                .init(
                    script: "export function update(value) { return value; }",
                    properties: [:],
                    seed: .init(5, 6, 7)
                )
            ],
            evaluationBudget: evaluationBudget
        )
    }

    private static func waitForRestart(
        _ client: WPESceneScriptXPCClient,
        timeout: Duration
    ) throws -> WPESceneScriptXPCClientResult.Completion {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if case .completed(let completion) = benignRequest(
                client,
                evaluationBudget: 0.05
            ) {
                return completion
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Issue.record("XPC service did not restart within \(timeout)")
        throw IntegrationFailure.noCompletion
    }

    private static func requireCompletion(
        _ result: WPESceneScriptXPCClientResult
    ) throws -> WPESceneScriptXPCClientResult.Completion {
        guard case .completed(let completion) = result else {
            Issue.record("Expected XPC completion, got \(result)")
            throw IntegrationFailure.noCompletion
        }
        return completion
    }

    private enum IntegrationFailure: Error {
        case noCompletion
    }
}
