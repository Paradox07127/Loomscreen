#if DEBUG && !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite(.serialized)
struct WPESceneScriptXPCDiagnosticsTests {
    @Test("Recorder keeps the newest bounded attempt and worker-generation history")
    func ringBuffersKeepNewestEntries() {
        let recorder = WPESceneScriptXPCDiagnosticsRecorder(
            attemptCapacity: 2,
            workerGenerationCapacity: 2
        )
        let firstWorker = UUID()
        let secondWorker = UUID()
        let thirdWorker = UUID()

        Self.finish(
            recorder,
            requestedItemCount: 1,
            workerInstanceID: firstWorker,
            workerPID: 101,
            finishedAtNanoseconds: 2
        )
        Self.finish(
            recorder,
            requestedItemCount: 2,
            workerInstanceID: secondWorker,
            workerPID: 102,
            finishedAtNanoseconds: 4
        )
        Self.finish(
            recorder,
            requestedItemCount: 3,
            workerInstanceID: thirdWorker,
            workerPID: 103,
            finishedAtNanoseconds: 6
        )

        let snapshot = recorder.snapshot(isEnabled: true)
        #expect(snapshot.attempts.map(\.requestedItemCount) == [2, 3])
        #expect(snapshot.workerGenerations.map(\.workerInstanceID) == [secondWorker, thirdWorker])
        #expect(snapshot.counters.attemptsRecorded == 3)
        #expect(snapshot.counters.maxInFlightAttempts == 1)
        #expect(snapshot.counters.currentInFlightAttempts == 0)
    }

    @Test("Reset clears bounded history and all counters")
    func resetClearsHistoryAndCounters() {
        let recorder = WPESceneScriptXPCDiagnosticsRecorder(
            attemptCapacity: 2,
            workerGenerationCapacity: 2
        )
        Self.finish(recorder, requestedItemCount: 1, finishedAtNanoseconds: 2)
        recorder.recordRecoveryAdmission(.suppressed)

        recorder.reset()

        let snapshot = recorder.snapshot(isEnabled: false)
        #expect(!snapshot.isEnabled)
        #expect(snapshot.attempts.isEmpty)
        #expect(snapshot.workerGenerations.isEmpty)
        #expect(snapshot.counters == WPESceneScriptXPCDiagnosticsCounters())
    }

    @Test("Reset discards completions that began before the reset boundary")
    func resetRejectsStaleInFlightCompletion() {
        let recorder = WPESceneScriptXPCDiagnosticsRecorder(
            attemptCapacity: 2,
            workerGenerationCapacity: 2
        )
        let stale = recorder.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 1
        )

        recorder.reset()
        recorder.finish(
            stale,
            outcome: .completed,
            measurements: .init(),
            workerInstanceID: UUID(),
            workerPID: 42,
            finishedAtNanoseconds: 2
        )

        #expect(recorder.snapshot(isEnabled: true).counters == .init())
        #expect(recorder.snapshot(isEnabled: true).attempts.isEmpty)
        #expect(recorder.snapshot(isEnabled: true).workerGenerations.isEmpty)

        let fresh = recorder.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 3
        )
        recorder.finish(
            fresh,
            outcome: .completed,
            measurements: .init(),
            workerInstanceID: nil,
            workerPID: nil,
            finishedAtNanoseconds: 4
        )
        #expect(recorder.snapshot(isEnabled: true).counters.completedAttempts == 1)
    }

    @Test("Attempt records contain only numeric metadata, UUID/PID, and outcomes")
    func attemptShapeCannotCarryContentText() throws {
        let recorder = WPESceneScriptXPCDiagnosticsRecorder(
            attemptCapacity: 1,
            workerGenerationCapacity: 1
        )
        let workerID = UUID()
        Self.finish(
            recorder,
            requestedItemCount: 2,
            workerInstanceID: workerID,
            workerPID: 321,
            finishedAtNanoseconds: 10
        )

        let attempt = try #require(recorder.snapshot(isEnabled: true).attempts.first)
        #expect(attempt.requestedItemCount == 2)
        #expect(attempt.uniqueSourceCount == 1)
        #expect(attempt.deadlineMilliseconds == 500)
        #expect(attempt.outcome == .completed)
        #expect(attempt.workerInstanceID == workerID)
        #expect(attempt.workerPID == 321)
        #expect(attempt.measurements == .init(workerReportedNanoseconds: 7))
        #expect(
            Set(Mirror(reflecting: attempt).children.compactMap(\.label)) == Set([
                "requestedItemCount",
                "uniqueSourceCount",
                "deadlineMilliseconds",
                "outcome",
                "measurements",
                "elapsedNanoseconds",
                "workerInstanceID",
                "workerPID",
            ])
        )
    }

    @Test("Outcome classification and recovery-gate counters are distinct")
    func classifiesOutcomesAndRecoveryGate() {
        let recorder = WPESceneScriptXPCDiagnosticsRecorder(
            attemptCapacity: 16,
            workerGenerationCapacity: 2
        )
        recorder.recordRecoveryAdmission(.suppressed)
        recorder.recordRecoveryAdmission(.admitted)
        for outcome in [
            WPESceneScriptXPCDiagnosticsOutcome.requestEncodingFailed,
            .circuitSuppressed,
            .proxyUnavailable,
            .replyUnavailable,
            .invalidResponse,
            .rejected,
            .completed,
        ] {
            Self.finish(recorder, requestedItemCount: 1, outcome: outcome, finishedAtNanoseconds: 2)
        }

        let counters = recorder.snapshot(isEnabled: true).counters
        #expect(counters.attemptsRecorded == 7)
        #expect(counters.transportFailures == 4)
        #expect(counters.rejectedAttempts == 1)
        #expect(counters.completedAttempts == 1)
        #expect(counters.circuitSuppressions == 1)
        #expect(counters.recoveryAdmissions == 1)
        #expect(counters.currentInFlightAttempts == 0)
    }

    @Test("In-flight measurements are bounded counters, not helper-process estimates")
    func tracksMaximumInFlightAttempts() {
        let recorder = WPESceneScriptXPCDiagnosticsRecorder(
            attemptCapacity: 4,
            workerGenerationCapacity: 1
        )
        let first = recorder.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 1
        )
        let second = recorder.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 2
        )
        let third = recorder.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 3
        )

        #expect(recorder.snapshot(isEnabled: true).counters.currentInFlightAttempts == 3)
        #expect(recorder.snapshot(isEnabled: true).counters.maxInFlightAttempts == 3)

        for token in [first, second, third] {
            recorder.finish(
                token,
                outcome: .completed,
                measurements: .init(),
                workerInstanceID: nil,
                workerPID: nil,
                finishedAtNanoseconds: 4
            )
        }
        let counters = recorder.snapshot(isEnabled: true).counters
        #expect(counters.currentInFlightAttempts == 0)
        #expect(counters.maxInFlightAttempts == 3)
    }

    @Test("Shared recorder is opt-in and its JSON export remains redacted")
    func sharedRecorderOptInAndJSONExport() throws {
        let wasEnabled = WPESceneScriptXPCDiagnostics.isEnabled
        defer {
            WPESceneScriptXPCDiagnostics.reset()
            WPESceneScriptXPCDiagnostics.setEnabled(wasEnabled)
        }

        WPESceneScriptXPCDiagnostics.setEnabled(false)
        WPESceneScriptXPCDiagnostics.reset()
        #expect(WPESceneScriptXPCDiagnostics.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 1
        ) == nil)

        WPESceneScriptXPCDiagnostics.setEnabled(true)
        let token = try #require(WPESceneScriptXPCDiagnostics.beginAttempt(
            requestedItemCount: 2,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 1
        ))
        let workerID = UUID()
        WPESceneScriptXPCDiagnostics.finish(
            token,
            outcome: .completed,
            measurements: .init(workerReportedNanoseconds: 7),
            workerInstanceID: workerID,
            workerPID: 321,
            finishedAtNanoseconds: 2
        )

        let data = try WPESceneScriptXPCDiagnostics.encodedSnapshot()
        let decoded = try JSONDecoder().decode(
            WPESceneScriptXPCDiagnosticsSnapshot.self,
            from: data
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(decoded.attempts.count == 1)
        #expect(decoded.attempts[0].workerInstanceID == workerID)
        #expect(!text.contains("private-script-or-scene-content"))
        #expect(!text.contains("path"))
        #expect(!text.contains("properties"))
    }

    private static func finish(
        _ recorder: WPESceneScriptXPCDiagnosticsRecorder,
        requestedItemCount: Int,
        outcome: WPESceneScriptXPCDiagnosticsOutcome = .completed,
        workerInstanceID: UUID? = nil,
        workerPID: Int32? = nil,
        finishedAtNanoseconds: UInt64
    ) {
        let token = recorder.beginAttempt(
            requestedItemCount: requestedItemCount,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 500,
            startedAtNanoseconds: 1
        )
        recorder.finish(
            token,
            outcome: outcome,
            measurements: .init(workerReportedNanoseconds: 7),
            workerInstanceID: workerInstanceID,
            workerPID: workerPID,
            finishedAtNanoseconds: finishedAtNanoseconds
        )
    }
}
#endif
