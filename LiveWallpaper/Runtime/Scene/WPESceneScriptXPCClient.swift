#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

enum WPESceneScriptXPCClientResult: Sendable, Equatable {
    struct Completion: Sendable, Equatable {
        let values: [SIMD3<Double>?]
        let workerInstanceID: UUID
        let workerPID: Int32
        let durationNanoseconds: UInt64
    }

    case completed(Completion)
    case rejected(SceneScriptXPCFailure)
    case transportFailure
}

final class WPESceneScriptXPCClient: @unchecked Sendable {
    static let shared = WPESceneScriptXPCClient()

    private static let processGate = NSLock()
    private static let recoveryCircuit = XPCRecoveryCircuit(cooldownSeconds: 10.5)

    var isEmbeddedServiceAvailable: Bool {
        let serviceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent(SceneScriptXPCServiceIdentity.productName, isDirectory: true)
        return FileManager.default.fileExists(atPath: serviceURL.path)
    }

    func evaluateStaticTransforms(
        canvasWidth: Double,
        canvasHeight: Double,
        requests: [WPESceneTransformScriptRequest],
        evaluationBudget: TimeInterval
    ) -> WPESceneScriptXPCClientResult {
        let wireItems = requests.map { request in
            SceneScriptXPCStaticTransformItem(
                script: request.script,
                properties: request.properties.mapValues(SceneScriptXPCPropertyValue.init),
                seed: SceneScriptXPCVector3(
                    x: request.seed.x,
                    y: request.seed.y,
                    z: request.seed.z
                )
            )
        }
        let uniqueSourceCount = Set(requests.map(\.script)).count
        let deadlineSeconds = min(
            max(evaluationBudget + Double(max(uniqueSourceCount - 1, 0)) * 0.025, 0.05),
            2.0
        )
        let requestID = UUID()
#if DEBUG && !LITE_BUILD
        let attemptStartedAtNanoseconds = Self.monotonicNowNanoseconds()
        let diagnosticsAttempt = WPESceneScriptXPCDiagnostics.beginAttempt(
            requestedItemCount: requests.count,
            uniqueSourceCount: uniqueSourceCount,
            deadlineMilliseconds: Int((deadlineSeconds * 1_000).rounded(.up)),
            startedAtNanoseconds: attemptStartedAtNanoseconds
        )
        var diagnosticsMeasurements = WPESceneScriptXPCDiagnosticsMeasurements()
        let encodingStartedAtNanoseconds = Self.monotonicNowNanoseconds()
#endif
        let request = SceneScriptXPCStaticTransformRequest(
            protocolVersion: SceneScriptXPCServiceIdentity.protocolVersion,
            requestID: requestID,
            deadlineMilliseconds: Int((deadlineSeconds * 1_000).rounded(.up)),
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            items: wireItems
        )
        guard let requestData = try? JSONEncoder().encode(request) else {
#if DEBUG && !LITE_BUILD
            diagnosticsMeasurements.requestEncodingNanoseconds = Self.elapsedNanoseconds(
                from: encodingStartedAtNanoseconds,
                to: Self.monotonicNowNanoseconds()
            )
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .requestEncodingFailed,
                measurements: diagnosticsMeasurements,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .transportFailure
        }
#if DEBUG && !LITE_BUILD
        diagnosticsMeasurements.requestEncodingNanoseconds = Self.elapsedNanoseconds(
            from: encodingStartedAtNanoseconds,
            to: Self.monotonicNowNanoseconds()
        )
        let processGateWaitStartedAtNanoseconds = Self.monotonicNowNanoseconds()
#endif

        Self.processGate.lock()
        defer { Self.processGate.unlock() }
#if DEBUG && !LITE_BUILD
        diagnosticsMeasurements.processGateWaitNanoseconds = Self.elapsedNanoseconds(
            from: processGateWaitStartedAtNanoseconds,
            to: Self.monotonicNowNanoseconds()
        )
#endif
        guard Self.recoveryCircuit.allowsAttempt else {
#if DEBUG && !LITE_BUILD
            WPESceneScriptXPCDiagnostics.recordRecoveryAdmission(.suppressed)
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .circuitSuppressed,
                measurements: diagnosticsMeasurements,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .transportFailure
        }
#if DEBUG && !LITE_BUILD
        if Self.recoveryCircuit.isRecoveryPending {
            WPESceneScriptXPCDiagnostics.recordRecoveryAdmission(.admitted)
        }
        let connectionSetupStartedAtNanoseconds = Self.monotonicNowNanoseconds()
#endif

        let connection = NSXPCConnection(
            serviceName: SceneScriptXPCServiceIdentity.serviceName
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SceneScriptXPCProtocol.self)
        let completion = ReplyCompletion()
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            completion.finish(with: nil)
        }) as? SceneScriptXPCProtocol else {
            connection.invalidate()
            Self.recoveryCircuit.recordTransportFailure()
#if DEBUG && !LITE_BUILD
            diagnosticsMeasurements.connectionSetupNanoseconds = Self.elapsedNanoseconds(
                from: connectionSetupStartedAtNanoseconds,
                to: Self.monotonicNowNanoseconds()
            )
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .proxyUnavailable,
                measurements: diagnosticsMeasurements,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .transportFailure
        }
#if DEBUG && !LITE_BUILD
        diagnosticsMeasurements.connectionSetupNanoseconds = Self.elapsedNanoseconds(
            from: connectionSetupStartedAtNanoseconds,
            to: Self.monotonicNowNanoseconds()
        )
#endif
        proxy.evaluateStaticTransforms(requestData) { responseData in
            completion.finish(with: responseData)
        }

        let clientGraceSeconds = 0.75
#if DEBUG && !LITE_BUILD
        let replyWaitStartedAtNanoseconds = Self.monotonicNowNanoseconds()
#endif
        guard completion.wait(timeout: deadlineSeconds + clientGraceSeconds),
              let responseData = completion.responseData else {
            connection.invalidate()
            Self.recoveryCircuit.recordTransportFailure()
#if DEBUG && !LITE_BUILD
            diagnosticsMeasurements.replyWaitNanoseconds = Self.elapsedNanoseconds(
                from: replyWaitStartedAtNanoseconds,
                to: Self.monotonicNowNanoseconds()
            )
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .replyUnavailable,
                measurements: diagnosticsMeasurements,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .transportFailure
        }
        connection.invalidate()
#if DEBUG && !LITE_BUILD
        diagnosticsMeasurements.replyWaitNanoseconds = Self.elapsedNanoseconds(
            from: replyWaitStartedAtNanoseconds,
            to: Self.monotonicNowNanoseconds()
        )
        let responseDecodeStartedAtNanoseconds = Self.monotonicNowNanoseconds()
#endif
        guard let response = try? JSONDecoder().decode(
            SceneScriptXPCStaticTransformResponse.self,
            from: responseData
        ),
              response.protocolVersion == SceneScriptXPCServiceIdentity.protocolVersion,
              response.requestID == requestID else {
            Self.recoveryCircuit.recordTransportFailure()
#if DEBUG && !LITE_BUILD
            diagnosticsMeasurements.responseDecodeNanoseconds = Self.elapsedNanoseconds(
                from: responseDecodeStartedAtNanoseconds,
                to: Self.monotonicNowNanoseconds()
            )
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .invalidResponse,
                measurements: diagnosticsMeasurements,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .transportFailure
        }
#if DEBUG && !LITE_BUILD
        diagnosticsMeasurements.responseDecodeNanoseconds = Self.elapsedNanoseconds(
            from: responseDecodeStartedAtNanoseconds,
            to: Self.monotonicNowNanoseconds()
        )
        diagnosticsMeasurements.workerReportedNanoseconds = response.durationNanoseconds
#endif
        if let failure = response.failure {
            Self.recoveryCircuit.recordHealthyReply()
#if DEBUG && !LITE_BUILD
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .rejected,
                measurements: diagnosticsMeasurements,
                workerInstanceID: response.workerInstanceID,
                workerPID: response.workerPID,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .rejected(failure)
        }
        guard response.results.count == requests.count else {
            Self.recoveryCircuit.recordTransportFailure()
#if DEBUG && !LITE_BUILD
            WPESceneScriptXPCDiagnostics.finish(
                diagnosticsAttempt,
                outcome: .invalidResponse,
                measurements: diagnosticsMeasurements,
                workerInstanceID: response.workerInstanceID,
                workerPID: response.workerPID,
                finishedAtNanoseconds: Self.monotonicNowNanoseconds()
            )
#endif
            return .transportFailure
        }
        Self.recoveryCircuit.recordHealthyReply()
#if DEBUG && !LITE_BUILD
        WPESceneScriptXPCDiagnostics.finish(
            diagnosticsAttempt,
            outcome: .completed,
            measurements: diagnosticsMeasurements,
            workerInstanceID: response.workerInstanceID,
            workerPID: response.workerPID,
            finishedAtNanoseconds: Self.monotonicNowNanoseconds()
        )
#endif
        return .completed(
            .init(
                values: response.results.map { value in
                    value.map { SIMD3<Double>($0.x, $0.y, $0.z) }
                },
                workerInstanceID: response.workerInstanceID,
                workerPID: response.workerPID,
                durationNanoseconds: response.durationNanoseconds
            )
        )
    }

#if DEBUG && !LITE_BUILD
    private static func monotonicNowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
#endif
}

private final class XPCRecoveryCircuit: @unchecked Sendable {
    private let lock = NSLock()
    private let cooldownNanoseconds: UInt64
    private var retryNotBeforeNanoseconds: UInt64 = 0

    init(cooldownSeconds: TimeInterval) {
        let nanoseconds = max(cooldownSeconds, 0) * 1_000_000_000
        cooldownNanoseconds = nanoseconds.isFinite && nanoseconds < Double(UInt64.max)
            ? UInt64(nanoseconds)
            : .max
    }

    var allowsAttempt: Bool {
        lock.lock()
        defer { lock.unlock() }
        return DispatchTime.now().uptimeNanoseconds >= retryNotBeforeNanoseconds
    }

    var isRecoveryPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retryNotBeforeNanoseconds != 0
    }

    func recordTransportFailure() {
        lock.lock()
        retryNotBeforeNanoseconds = Self.saturatingAdd(
            DispatchTime.now().uptimeNanoseconds,
            cooldownNanoseconds
        )
        lock.unlock()
    }

    func recordHealthyReply() {
        lock.lock()
        retryNotBeforeNanoseconds = 0
        lock.unlock()
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

private final class ReplyCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private(set) var responseData: Data?

    func finish(with data: Data?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        responseData = data
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + max(timeout, 0)) == .success
    }
}

private extension SceneScriptXPCPropertyValue {
    init(_ value: WPESceneScriptPropertyValue) {
        switch value {
        case .number(let number): self = .number(number)
        case .bool(let bool): self = .bool(bool)
        case .string(let string): self = .string(string)
        }
    }
}
#endif
