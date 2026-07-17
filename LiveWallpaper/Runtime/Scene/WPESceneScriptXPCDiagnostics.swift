#if DEBUG && !LITE_BUILD
import Foundation

/// Opt-in, memory-only measurements for the shared SceneScript XPC helper.
/// The payload intentionally contains no scene or script-derived text.
enum WPESceneScriptXPCDiagnostics {
    static let sharedRecorder = WPESceneScriptXPCDiagnosticsRecorder(
        attemptCapacity: 128,
        workerGenerationCapacity: 32
    )
    private static let state = WPESceneScriptXPCDiagnosticsState()

    static var isEnabled: Bool {
        state.isEnabled
    }

    static func setEnabled(_ enabled: Bool) {
        state.setEnabled(enabled)
    }

    static func reset() {
        sharedRecorder.reset()
    }

    static func snapshot() -> WPESceneScriptXPCDiagnosticsSnapshot {
        sharedRecorder.snapshot(isEnabled: isEnabled)
    }

    static func encodedSnapshot() throws -> Data {
        try encodedSnapshot(snapshot())
    }

    static func encodedSnapshot(
        _ snapshot: WPESceneScriptXPCDiagnosticsSnapshot
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func beginAttempt(
        requestedItemCount: Int,
        uniqueSourceCount: Int,
        deadlineMilliseconds: Int,
        startedAtNanoseconds: UInt64
    ) -> WPESceneScriptXPCDiagnosticsAttemptToken? {
        guard isEnabled else { return nil }
        return sharedRecorder.beginAttempt(
            requestedItemCount: requestedItemCount,
            uniqueSourceCount: uniqueSourceCount,
            deadlineMilliseconds: deadlineMilliseconds,
            startedAtNanoseconds: startedAtNanoseconds
        )
    }

    static func recordRecoveryAdmission(
        _ disposition: WPESceneScriptXPCRecoveryAdmission
    ) {
        guard isEnabled else { return }
        sharedRecorder.recordRecoveryAdmission(disposition)
    }

    static func finish(
        _ token: WPESceneScriptXPCDiagnosticsAttemptToken?,
        outcome: WPESceneScriptXPCDiagnosticsOutcome,
        measurements: WPESceneScriptXPCDiagnosticsMeasurements,
        workerInstanceID: UUID? = nil,
        workerPID: Int32? = nil,
        finishedAtNanoseconds: UInt64
    ) {
        guard let token else { return }
        sharedRecorder.finish(
            token,
            outcome: outcome,
            measurements: measurements,
            workerInstanceID: workerInstanceID,
            workerPID: workerPID,
            finishedAtNanoseconds: finishedAtNanoseconds
        )
    }
}

enum WPESceneScriptXPCDiagnosticsOutcome: String, Sendable, Codable, Equatable {
    case requestEncodingFailed
    case circuitSuppressed
    case proxyUnavailable
    case replyUnavailable
    case invalidResponse
    case rejected
    case completed
}

enum WPESceneScriptXPCRecoveryAdmission: String, Sendable, Codable, Equatable {
    case admitted
    case suppressed
}

struct WPESceneScriptXPCDiagnosticsMeasurements: Sendable, Codable, Equatable {
    var requestEncodingNanoseconds: UInt64 = 0
    var processGateWaitNanoseconds: UInt64 = 0
    var connectionSetupNanoseconds: UInt64 = 0
    var replyWaitNanoseconds: UInt64 = 0
    var responseDecodeNanoseconds: UInt64 = 0
    var workerReportedNanoseconds: UInt64 = 0
}

struct WPESceneScriptXPCDiagnosticsAttempt: Sendable, Codable, Equatable {
    let requestedItemCount: UInt64
    let uniqueSourceCount: UInt64
    let deadlineMilliseconds: UInt64
    let outcome: WPESceneScriptXPCDiagnosticsOutcome
    let measurements: WPESceneScriptXPCDiagnosticsMeasurements
    let elapsedNanoseconds: UInt64
    let workerInstanceID: UUID?
    let workerPID: Int32?
}

struct WPESceneScriptXPCDiagnosticsWorkerGeneration: Sendable, Codable, Equatable {
    let workerInstanceID: UUID
    let workerPID: Int32
    let firstSeenNanoseconds: UInt64
    var lastSeenNanoseconds: UInt64
    var completedAttemptCount: UInt64
}

struct WPESceneScriptXPCDiagnosticsCounters: Sendable, Codable, Equatable {
    var attemptsRecorded: UInt64 = 0
    var completedAttempts: UInt64 = 0
    var rejectedAttempts: UInt64 = 0
    var transportFailures: UInt64 = 0
    var circuitSuppressions: UInt64 = 0
    var recoveryAdmissions: UInt64 = 0
    var currentInFlightAttempts: UInt64 = 0
    var maxInFlightAttempts: UInt64 = 0
}

struct WPESceneScriptXPCDiagnosticsSnapshot: Sendable, Codable, Equatable {
    let isEnabled: Bool
    let attempts: [WPESceneScriptXPCDiagnosticsAttempt]
    let workerGenerations: [WPESceneScriptXPCDiagnosticsWorkerGeneration]
    let counters: WPESceneScriptXPCDiagnosticsCounters
}

struct WPESceneScriptXPCDiagnosticsAttemptToken: Sendable, Equatable {
    /// Reset advances the recorder epoch so a completion that began before the
    /// reset cannot repopulate the user-cleared diagnostic history.
    fileprivate let recorderEpoch: UInt64
    fileprivate let startedAtNanoseconds: UInt64
    fileprivate let requestedItemCount: UInt64
    fileprivate let uniqueSourceCount: UInt64
    fileprivate let deadlineMilliseconds: UInt64
}

private final class WPESceneScriptXPCDiagnosticsState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }
}

final class WPESceneScriptXPCDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let attemptCapacity: Int
    private let workerGenerationCapacity: Int
    private var attempts: [WPESceneScriptXPCDiagnosticsAttempt] = []
    private var workerGenerations: [WPESceneScriptXPCDiagnosticsWorkerGeneration] = []
    private var counters = WPESceneScriptXPCDiagnosticsCounters()
    private var epoch: UInt64 = 0

    init(attemptCapacity: Int, workerGenerationCapacity: Int) {
        self.attemptCapacity = max(attemptCapacity, 1)
        self.workerGenerationCapacity = max(workerGenerationCapacity, 1)
    }

    func beginAttempt(
        requestedItemCount: Int,
        uniqueSourceCount: Int,
        deadlineMilliseconds: Int,
        startedAtNanoseconds: UInt64
    ) -> WPESceneScriptXPCDiagnosticsAttemptToken {
        lock.lock()
        let recorderEpoch = epoch
        counters.currentInFlightAttempts = Self.saturatingAdd(
            counters.currentInFlightAttempts,
            1
        )
        counters.maxInFlightAttempts = max(
            counters.maxInFlightAttempts,
            counters.currentInFlightAttempts
        )
        lock.unlock()
        return .init(
            recorderEpoch: recorderEpoch,
            startedAtNanoseconds: startedAtNanoseconds,
            requestedItemCount: Self.nonNegative(requestedItemCount),
            uniqueSourceCount: Self.nonNegative(uniqueSourceCount),
            deadlineMilliseconds: Self.nonNegative(deadlineMilliseconds)
        )
    }

    func recordRecoveryAdmission(_ disposition: WPESceneScriptXPCRecoveryAdmission) {
        lock.lock()
        switch disposition {
        case .admitted:
            counters.recoveryAdmissions = Self.saturatingAdd(counters.recoveryAdmissions, 1)
        case .suppressed:
            counters.circuitSuppressions = Self.saturatingAdd(counters.circuitSuppressions, 1)
        }
        lock.unlock()
    }

    func finish(
        _ token: WPESceneScriptXPCDiagnosticsAttemptToken,
        outcome: WPESceneScriptXPCDiagnosticsOutcome,
        measurements: WPESceneScriptXPCDiagnosticsMeasurements,
        workerInstanceID: UUID?,
        workerPID: Int32?,
        finishedAtNanoseconds: UInt64
    ) {
        lock.lock()
        guard token.recorderEpoch == epoch else {
            lock.unlock()
            return
        }
        let attempt = WPESceneScriptXPCDiagnosticsAttempt(
            requestedItemCount: token.requestedItemCount,
            uniqueSourceCount: token.uniqueSourceCount,
            deadlineMilliseconds: token.deadlineMilliseconds,
            outcome: outcome,
            measurements: measurements,
            elapsedNanoseconds: Self.elapsed(
                from: token.startedAtNanoseconds,
                to: finishedAtNanoseconds
            ),
            workerInstanceID: workerInstanceID,
            workerPID: workerPID
        )
        counters.currentInFlightAttempts = Self.saturatingSubtract(
            counters.currentInFlightAttempts,
            1
        )
        counters.attemptsRecorded = Self.saturatingAdd(counters.attemptsRecorded, 1)
        switch outcome {
        case .completed:
            counters.completedAttempts = Self.saturatingAdd(counters.completedAttempts, 1)
        case .rejected:
            counters.rejectedAttempts = Self.saturatingAdd(counters.rejectedAttempts, 1)
        case .circuitSuppressed:
            break
        case .requestEncodingFailed, .proxyUnavailable, .replyUnavailable, .invalidResponse:
            counters.transportFailures = Self.saturatingAdd(counters.transportFailures, 1)
        }
        append(attempt, to: &attempts, capacity: attemptCapacity)
        if let workerInstanceID, let workerPID {
            recordWorkerGeneration(
                workerInstanceID: workerInstanceID,
                workerPID: workerPID,
                seenAtNanoseconds: finishedAtNanoseconds,
                completed: outcome == .completed
            )
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        epoch &+= 1
        attempts.removeAll(keepingCapacity: true)
        workerGenerations.removeAll(keepingCapacity: true)
        counters = .init()
        lock.unlock()
    }

    func snapshot(isEnabled: Bool) -> WPESceneScriptXPCDiagnosticsSnapshot {
        lock.lock()
        let snapshot = WPESceneScriptXPCDiagnosticsSnapshot(
            isEnabled: isEnabled,
            attempts: attempts,
            workerGenerations: workerGenerations,
            counters: counters
        )
        lock.unlock()
        return snapshot
    }

    private func recordWorkerGeneration(
        workerInstanceID: UUID,
        workerPID: Int32,
        seenAtNanoseconds: UInt64,
        completed: Bool
    ) {
        if let index = workerGenerations.firstIndex(where: {
            $0.workerInstanceID == workerInstanceID && $0.workerPID == workerPID
        }) {
            workerGenerations[index].lastSeenNanoseconds = seenAtNanoseconds
            if completed {
                workerGenerations[index].completedAttemptCount = Self.saturatingAdd(
                    workerGenerations[index].completedAttemptCount,
                    1
                )
            }
            return
        }
        let generation = WPESceneScriptXPCDiagnosticsWorkerGeneration(
            workerInstanceID: workerInstanceID,
            workerPID: workerPID,
            firstSeenNanoseconds: seenAtNanoseconds,
            lastSeenNanoseconds: seenAtNanoseconds,
            completedAttemptCount: completed ? 1 : 0
        )
        append(generation, to: &workerGenerations, capacity: workerGenerationCapacity)
    }

    private func append<Element>(_ element: Element, to values: inout [Element], capacity: Int) {
        if values.count == capacity {
            values.removeFirst()
        }
        values.append(element)
    }

    private static func nonNegative(_ value: Int) -> UInt64 {
        guard value > 0 else { return 0 }
        return UInt64(value)
    }

    private static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func saturatingSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}
#endif
