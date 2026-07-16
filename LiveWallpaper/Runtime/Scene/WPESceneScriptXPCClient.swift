#if !LITE_BUILD
import Foundation

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
        let request = SceneScriptXPCStaticTransformRequest(
            protocolVersion: SceneScriptXPCServiceIdentity.protocolVersion,
            requestID: requestID,
            deadlineMilliseconds: Int((deadlineSeconds * 1_000).rounded(.up)),
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            items: wireItems
        )
        guard let requestData = try? JSONEncoder().encode(request) else {
            return .transportFailure
        }

        Self.processGate.lock()
        defer { Self.processGate.unlock() }
        guard Self.recoveryCircuit.allowsAttempt else {
            return .transportFailure
        }

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
            return .transportFailure
        }
        proxy.evaluateStaticTransforms(requestData) { responseData in
            completion.finish(with: responseData)
        }

        let clientGraceSeconds = 0.75
        guard completion.wait(timeout: deadlineSeconds + clientGraceSeconds),
              let responseData = completion.responseData else {
            connection.invalidate()
            Self.recoveryCircuit.recordTransportFailure()
            return .transportFailure
        }
        connection.invalidate()
        guard let response = try? JSONDecoder().decode(
            SceneScriptXPCStaticTransformResponse.self,
            from: responseData
        ),
              response.protocolVersion == SceneScriptXPCServiceIdentity.protocolVersion,
              response.requestID == requestID else {
            Self.recoveryCircuit.recordTransportFailure()
            return .transportFailure
        }
        Self.recoveryCircuit.recordHealthyReply()
        if let failure = response.failure {
            return .rejected(failure)
        }
        guard response.results.count == requests.count else {
            return .transportFailure
        }
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
}

private final class XPCRecoveryCircuit: @unchecked Sendable {
    private let lock = NSLock()
    private let cooldownNanoseconds: UInt64
    private var retryNotBeforeNanoseconds: UInt64 = 0

    init(cooldownSeconds: TimeInterval) {
        cooldownNanoseconds = UInt64(max(cooldownSeconds, 0) * 1_000_000_000)
    }

    var allowsAttempt: Bool {
        lock.lock()
        defer { lock.unlock() }
        return DispatchTime.now().uptimeNanoseconds >= retryNotBeforeNanoseconds
    }

    func recordTransportFailure() {
        lock.lock()
        retryNotBeforeNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ cooldownNanoseconds
        lock.unlock()
    }

    func recordHealthyReply() {
        lock.lock()
        retryNotBeforeNanoseconds = 0
        lock.unlock()
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
