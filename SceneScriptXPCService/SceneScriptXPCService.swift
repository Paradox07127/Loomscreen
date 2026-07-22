import Darwin
import Foundation
import JavaScriptCore

final class SceneScriptXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let worker = SceneScriptXPCWorker()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: SceneScriptXPCProtocol.self)
        newConnection.exportedObject = worker
        newConnection.resume()
        return true
    }
}

final class SceneScriptXPCWorker: NSObject, SceneScriptXPCProtocol {
    private enum Limits {
        static let maximumRequestBytes = 4 * 1_024 * 1_024
        static let maximumBatchItems = 256
        static let maximumUniqueSources = 64
        static let maximumScriptBytes = 512 * 1_024
        static let maximumTotalScriptBytes = 4 * 1_024 * 1_024
        static let maximumPropertiesPerItem = 256
        static let maximumPropertyKeyBytes = 256
        static let maximumPropertyStringBytes = 64 * 1_024
        static let minimumDeadlineMilliseconds = 50
        static let maximumDeadlineMilliseconds = 2_000
        static let maximumCanvasDimension = 1_000_000.0
    }

    private let workerInstanceID = UUID()
    private let evaluationLock = NSLock()

    func evaluateStaticTransforms(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        evaluationLock.lock()
        defer { evaluationLock.unlock() }

        guard requestData.count <= Limits.maximumRequestBytes,
              let request = try? JSONDecoder().decode(
                  SceneScriptXPCStaticTransformRequest.self,
                  from: requestData
              ) else {
            reply(encodedFailure(.malformedRequest, requestID: UUID()))
            return
        }
        guard request.protocolVersion == SceneScriptXPCServiceIdentity.protocolVersion else {
            reply(encodedFailure(.unsupportedProtocol, requestID: request.requestID))
            return
        }
        guard validates(request) else {
            reply(encodedFailure(.resourceLimitExceeded, requestID: request.requestID))
            return
        }

        let deadlineMilliseconds = min(
            max(request.deadlineMilliseconds, Limits.minimumDeadlineMilliseconds),
            Limits.maximumDeadlineMilliseconds
        )
        let deadline = SceneScriptXPCHardDeadline(milliseconds: deadlineMilliseconds)
        let started = DispatchTime.now().uptimeNanoseconds
        deadline.arm()

        let results = StaticTransformBatchEvaluator(
            canvasWidth: request.canvasWidth,
            canvasHeight: request.canvasHeight,
            maximumUniqueSources: Limits.maximumUniqueSources
        ).evaluate(request.items)
        let response = SceneScriptXPCStaticTransformResponse(
            protocolVersion: SceneScriptXPCServiceIdentity.protocolVersion,
            requestID: request.requestID,
            workerInstanceID: workerInstanceID,
            workerPID: ProcessInfo.processInfo.processIdentifier,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            results: results,
            failure: nil
        )
        guard let data = try? JSONEncoder().encode(response), deadline.disarm() else {
            return
        }
        reply(data)
    }

    private func validates(_ request: SceneScriptXPCStaticTransformRequest) -> Bool {
        guard !request.items.isEmpty,
              request.items.count <= Limits.maximumBatchItems,
              request.canvasWidth.isFinite,
              request.canvasHeight.isFinite,
              request.canvasWidth > 0,
              request.canvasHeight > 0,
              request.canvasWidth <= Limits.maximumCanvasDimension,
              request.canvasHeight <= Limits.maximumCanvasDimension else {
            return false
        }

        var totalScriptBytes = 0
        for item in request.items {
            let scriptBytes = item.script.lengthOfBytes(using: .utf8)
            totalScriptBytes += scriptBytes
            guard scriptBytes > 0,
                  scriptBytes <= Limits.maximumScriptBytes,
                  totalScriptBytes <= Limits.maximumTotalScriptBytes,
                  SceneScriptStaticExecutionPolicy.isStaticallyResolvable(item.script),
                  item.properties.count <= Limits.maximumPropertiesPerItem,
                  item.seed.x.isFinite,
                  item.seed.y.isFinite,
                  item.seed.z.isFinite else {
                return false
            }
            for (key, value) in item.properties {
                guard !key.isEmpty,
                      key.lengthOfBytes(using: .utf8) <= Limits.maximumPropertyKeyBytes else {
                    return false
                }
                switch value {
                case .number(let number):
                    guard number.isFinite else { return false }
                case .bool:
                    break
                case .string(let string):
                    guard string.lengthOfBytes(using: .utf8) <= Limits.maximumPropertyStringBytes else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func encodedFailure(
        _ failure: SceneScriptXPCFailure,
        requestID: UUID
    ) -> Data {
        let response = SceneScriptXPCStaticTransformResponse(
            protocolVersion: SceneScriptXPCServiceIdentity.protocolVersion,
            requestID: requestID,
            workerInstanceID: workerInstanceID,
            workerPID: ProcessInfo.processInfo.processIdentifier,
            durationNanoseconds: 0,
            results: [],
            failure: failure
        )
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

private final class SceneScriptXPCHardDeadline: @unchecked Sendable {
    private static let watchdogQueue = DispatchQueue(
        label: "com.loomscreen.scenescript-xpc.watchdog",
        qos: .userInteractive
    )

    private let lock = NSLock()
    private let milliseconds: Int
    private var armed = false
    private var workItem: DispatchWorkItem?

    init(milliseconds: Int) {
        self.milliseconds = milliseconds
    }

    func arm() {
        lock.lock()
        guard !armed else {
            lock.unlock()
            return
        }
        armed = true
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        workItem = item
        lock.unlock()
        Self.watchdogQueue.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: item
        )
    }

    func disarm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return false }
        armed = false
        workItem?.cancel()
        workItem = nil
        return true
    }

    private func fire() {
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        armed = false
        lock.unlock()
        // A clean exit tears down a wedged JavaScriptCore process without marking the demand-launched service as crashed.
        _exit(EXIT_SUCCESS)
    }
}

private final class StaticTransformBatchEvaluator {
    private struct CachedContext {
        let context: JSContext
        let declaredDefaults: [String: SceneScriptXPCPropertyValue]
    }

    private final class ExceptionFlag {
        var didThrow = false
    }

    private let canvasWidth: Double
    private let canvasHeight: Double
    private let maximumUniqueSources: Int
    private let exception = ExceptionFlag()
    private var contextsBySource: [String: CachedContext] = [:]
    private var rejectedSources: Set<String> = []

    init(canvasWidth: Double, canvasHeight: Double, maximumUniqueSources: Int) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.maximumUniqueSources = maximumUniqueSources
    }

    func evaluate(
        _ items: [SceneScriptXPCStaticTransformItem]
    ) -> [SceneScriptXPCVector3?] {
        items.map(evaluate)
    }

    private func evaluate(
        _ item: SceneScriptXPCStaticTransformItem
    ) -> SceneScriptXPCVector3? {
        guard let cached = context(for: item.script) else { return nil }
        installProperties(
            overrides: item.properties,
            declaredDefaults: cached.declaredDefaults,
            in: cached.context
        )
        guard !exception.didThrow,
              let update = cached.context.objectForKeyedSubscript("update"),
              !update.isUndefined,
              update.hasProperty("call"),
              let value = JSValue(newObjectIn: cached.context) else {
            return nil
        }

        value.setObject(item.seed.x, forKeyedSubscript: "x" as NSString)
        value.setObject(item.seed.y, forKeyedSubscript: "y" as NSString)
        value.setObject(item.seed.z, forKeyedSubscript: "z" as NSString)
        exception.didThrow = false
        guard let result = update.call(withArguments: [value]),
              !exception.didThrow,
              !result.isUndefined,
              !result.isNull,
              result.isObject,
              let xValue = result.objectForKeyedSubscript("x"),
              let yValue = result.objectForKeyedSubscript("y") else {
            return nil
        }
        let x = xValue.toDouble()
        let y = yValue.toDouble()
        guard x.isFinite, y.isFinite else { return nil }
        let candidateZ = result.objectForKeyedSubscript("z")?.toDouble() ?? item.seed.z
        let z = candidateZ.isFinite ? candidateZ : item.seed.z
        return SceneScriptXPCVector3(x: x, y: y, z: z)
    }

    private func context(for source: String) -> CachedContext? {
        if let cached = contextsBySource[source] { return cached }
        guard !rejectedSources.contains(source),
              contextsBySource.count < maximumUniqueSources,
              let context = JSContext() else {
            rejectedSources.insert(source)
            return nil
        }
        installSandbox(in: context)
        WPESceneScriptBaseclasses.install(in: context)
        context.exceptionHandler = { [exception] _, _ in exception.didThrow = true }
        exception.didThrow = false
        let prepared = normalizeScriptProperties(in: preprocess(source))
        _ = context.evaluateScript(prepared)
        guard !exception.didThrow else {
            rejectedSources.insert(source)
            return nil
        }
        let cached = CachedContext(
            context: context,
            declaredDefaults: declaredDefaults(
                from: context.objectForKeyedSubscript("scriptProperties")
            )
        )
        contextsBySource[source] = cached
        return cached
    }

    private func preprocess(_ script: String) -> String {
        var prepared = script
        for space in ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{FEFF}"] {
            prepared = prepared.replacingOccurrences(of: space, with: " ")
        }
        prepared = prepared.replacingOccurrences(of: "'use strict';", with: "")
        prepared = prepared.replacingOccurrences(of: "\"use strict\";", with: "")
        prepared = prepared.replacingOccurrences(of: "export function", with: "function")
        prepared = prepared.replacingOccurrences(of: "export var", with: "var")
        prepared = prepared.replacingOccurrences(of: "export let", with: "let")
        prepared = prepared.replacingOccurrences(of: "export const", with: "const")
        return prepared
    }

    private func normalizeScriptProperties(in script: String) -> String {
        script
            .replacingOccurrences(of: "let scriptProperties", with: "var scriptProperties")
            .replacingOccurrences(of: "const scriptProperties", with: "var scriptProperties")
    }

    private func installSandbox(in context: JSContext) {
        let console = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
        let log: @convention(block) (JSValue) -> Void = { _ in }
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let engine = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
        let canvas = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
        canvas.setObject(canvasWidth, forKeyedSubscript: "x" as NSString)
        canvas.setObject(canvasHeight, forKeyedSubscript: "y" as NSString)
        engine.setObject(canvas, forKeyedSubscript: "canvasSize" as NSString)
        engine.setObject(canvas, forKeyedSubscript: "screenResolution" as NSString)
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)

        let createScriptProperties: @convention(block) () -> JSValue = {
            let proxy = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let register: @convention(block) (JSValue) -> JSValue = { config in
                guard config.isObject,
                      let nameValue = config.objectForKeyedSubscript("name"),
                      nameValue.isString,
                      let name = nameValue.toString(),
                      !name.isEmpty else {
                    return proxy
                }
                if let value = config.objectForKeyedSubscript("value"), !value.isUndefined {
                    proxy.setObject(value, forKeyedSubscript: name as NSString)
                } else if let options = config.objectForKeyedSubscript("options"),
                          options.isArray,
                          let first = options.atIndex(0),
                          first.isObject,
                          let value = first.objectForKeyedSubscript("value"),
                          !value.isUndefined {
                    proxy.setObject(value, forKeyedSubscript: name as NSString)
                }
                return proxy
            }
            for name in [
                "addCheckbox", "addText", "addSlider", "addColor", "addCombo",
                "addFile", "addUserShortcut", "addGroup", "finish"
            ] {
                proxy.setObject(register, forKeyedSubscript: name as NSString)
            }
            return proxy
        }
        context.setObject(
            createScriptProperties,
            forKeyedSubscript: "createScriptProperties" as NSString
        )
    }

    private func declaredDefaults(
        from value: JSValue?
    ) -> [String: SceneScriptXPCPropertyValue] {
        guard let dictionary = value?.toDictionary() as? [String: Any] else { return [:] }
        var defaults: [String: SceneScriptXPCPropertyValue] = [:]
        for (name, raw) in dictionary {
            if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    defaults[name] = .bool(number.boolValue)
                } else if number.doubleValue.isFinite {
                    defaults[name] = .number(number.doubleValue)
                }
            } else if let string = raw as? String {
                defaults[name] = .string(string)
            }
        }
        return defaults
    }

    private func installProperties(
        overrides: [String: SceneScriptXPCPropertyValue],
        declaredDefaults: [String: SceneScriptXPCPropertyValue],
        in context: JSContext
    ) {
        exception.didThrow = false
        guard let properties = JSValue(newObjectIn: context) else {
            exception.didThrow = true
            return
        }
        for (name, value) in declaredDefaults {
            properties.setObject(value.bridged, forKeyedSubscript: name as NSString)
        }
        for (name, value) in overrides {
            properties.setObject(value.bridged, forKeyedSubscript: name as NSString)
        }
        context.setObject(properties, forKeyedSubscript: "scriptProperties" as NSString)
    }
}

private extension SceneScriptXPCPropertyValue {
    var bridged: Any {
        switch self {
        case .number(let value): value
        case .bool(let value): value
        case .string(let value): value
        }
    }
}
