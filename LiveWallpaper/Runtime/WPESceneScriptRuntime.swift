#if !LITE_BUILD
import Foundation
import JavaScriptCore

/// Sandboxed evaluator for one WPE SceneScript module. Each scripted
/// scene field (text content, origin, color, alpha, …) gets its own
/// runtime so per-property scripts stay isolated and one bad script
/// can't poison another field's evaluation.
///
/// Sandbox: the JSContext exposes a small surface — `engine`,
/// `thisLayer` (read-only stand-in), and the host's `localstorage`
/// stub. No file/network/process APIs reach the script. The
/// preprocessor strips ESM `export` keywords so the WPE-style
/// `export function update(value)` shape evaluates as a plain
/// declaration we can later invoke through the JSContext.
///
/// Execution-time containment: JavaScriptCore has no public execution
/// time limit, so an untrusted `while(true){}` would otherwise hang the
/// calling (load/render) thread forever. Every evaluation therefore runs
/// on the instance's dedicated serial queue while the caller waits with a
/// wall-clock budget; on timeout the instance is poisoned — `tickString`
/// freezes at `lastValue` and the engine is quarantined (kept alive, never
/// touched again) because releasing a JSContext whose VM lock is held by
/// the hung worker could block the releasing thread.
@MainActor
final class WPESceneScriptInstance {
    private let engine: Engine
    private let hasUpdateFunction: Bool
    private let tickBudget: TimeInterval
    private var isPoisoned = false
    private(set) var lastValue: String

    /// Engines whose worker is stuck inside JS. Retained forever — see the
    /// class doc. Bounded by the number of hostile scripts ever loaded.
    private static var quarantine: [Engine] = []

    /// `script` is the JS source captured from `text: { script: ...
    /// Budgets: setup covers the whole module body + `init()` (allow real
    /// work); per-frame `update()` is expected to be microseconds, so an
    /// overrun only ever means a runaway loop. Tests inject smaller values.
    init(
        script: String,
        initialValue: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5
    ) throws {
        self.lastValue = initialValue
        self.tickBudget = tickBudget
        self.engine = Engine()
        var prepared = Self.preprocess(script: script)
        // Normalize `let/const scriptProperties` → `var` only when injecting, so
        // the scene's overrides reach a reassignable global. No-op otherwise.
        if !scriptProperties.isEmpty {
            prepared = wpeNormalizeScriptPropertiesDeclaration(prepared)
        }
        guard let outcome = engine.setUp(
            script: prepared,
            scriptProperties: scriptProperties,
            budget: setupBudget
        ) else {
            Self.quarantine.append(engine)
            isPoisoned = true
            Logger.warning(
                "SceneScript setup exceeded \(setupBudget)s — script disabled",
                category: .wpeRender
            )
            throw WPESceneScriptError.executionTimedOut
        }
        switch outcome {
        case .contextUnavailable:
            throw WPESceneScriptError.contextUnavailable
        case .ready(let hasUpdate):
            self.hasUpdateFunction = hasUpdate
        }
    }

    /// Tick the script's `update(value)` and return the latest value as a String.
    func tickString() -> String {
        guard hasUpdateFunction, !isPoisoned else { return lastValue }
        guard let outcome = engine.tick(lastValue: lastValue, budget: tickBudget) else {
            isPoisoned = true
            Self.quarantine.append(engine)
            Logger.warning(
                "SceneScript update() exceeded \(tickBudget)s — script frozen at its last value",
                category: .wpeRender
            )
            return lastValue
        }
        if let newValue = outcome {
            lastValue = newValue
        }
        return lastValue
    }

    /// Owns the JSContext and the only thread allowed to touch it. The class
    /// is `@unchecked Sendable` because `context`/`updateFunction` are only
    /// ever accessed on `queue`; callers exchange plain `String`s.
    private final class Engine: @unchecked Sendable {
        enum SetupOutcome {
            case ready(hasUpdate: Bool)
            case contextUnavailable
        }

        private let queue = DispatchQueue(
            label: "com.livewallpaper.wpe-scenescript",
            qos: .userInitiated
        )
        private var context: JSContext?
        private var updateFunction: JSValue?

        /// nil = budget exceeded (worker still running; engine must be quarantined).
        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            budget: TimeInterval
        ) -> SetupOutcome? {
            runWithBudget(budget) {
                self.setUpOnQueue(script: script, scriptProperties: scriptProperties)
            }
        }

        /// Outer nil = budget exceeded; inner nil = no new value (keep last).
        func tick(lastValue: String, budget: TimeInterval) -> String?? {
            runWithBudget(budget) { self.tickOnQueue(lastValue: lastValue) }
        }

        private func runWithBudget<T>(
            _ budget: TimeInterval,
            _ work: @escaping @Sendable () -> T
        ) -> T? {
            let done = DispatchSemaphore(value: 0)
            let box = ResultBox<T>()
            queue.async {
                box.value = work()
                done.signal()
            }
            guard done.wait(timeout: .now() + budget) == .success else { return nil }
            return box.value
        }

        private func setUpOnQueue(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue]
        ) -> SetupOutcome {
            guard let context = JSContext() else {
                return .contextUnavailable
            }
            self.context = context
            WPESceneScriptInstance.installSandbox(in: context)
            WPESceneScriptBaseclasses.install(in: context)
            context.exceptionHandler = { _, ex in
                _ = ex
            }
            let _ = context.evaluateScript(script)

            // Overlay the scene's per-object scriptProperty overrides onto the
            // script's declared defaults, so the text renders with the scene's
            // configuration (e.g. dayFormat/showDay) instead of bare defaults.
            if !scriptProperties.isEmpty {
                wpeInstallScriptProperties(
                    overrides: scriptProperties,
                    declaredDefaults: wpeDeclaredScriptPropertyDefaults(
                        context.objectForKeyedSubscript("scriptProperties")
                    ),
                    into: context
                )
            }

            let updateValue = context.objectForKeyedSubscript("update")
            if let updateValue, !updateValue.isUndefined, updateValue.hasProperty("call") {
                updateFunction = updateValue
            } else {
                updateFunction = nil
            }
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                _ = initFn.call(withArguments: [])
            }
            return .ready(hasUpdate: updateFunction != nil)
        }

        private func tickOnQueue(lastValue: String) -> String? {
            guard let context, let updateFunction else { return nil }
            let arg = JSValue(object: lastValue, in: context) ?? JSValue(nullIn: context)!
            guard let result = updateFunction.call(withArguments: [arg as Any]),
                  !result.isUndefined && !result.isNull else {
                return nil
            }
            if result.isString, let s = result.toString() {
                return s
            }
            if result.isNumber {
                return String(result.toDouble())
            }
            return nil
        }

        private final class ResultBox<T>: @unchecked Sendable {
            var value: T?
        }
    }

    /// Strip `export` keywords + `'use strict'` so the script body evaluates as flat top-level declarations the JSContext can look up by name.
    /// `nonisolated`: also called by `WPETransformScriptEvaluator` off the main actor.
    nonisolated fileprivate static func preprocess(script: String) -> String {
        var s = script
        s = s.replacingOccurrences(of: "'use strict';", with: "")
        s = s.replacingOccurrences(of: "\"use strict\";", with: "")
        s = s.replacingOccurrences(of: "export function", with: "function")
        s = s.replacingOccurrences(of: "export var", with: "var")
        s = s.replacingOccurrences(of: "export let", with: "let")
        s = s.replacingOccurrences(of: "export const", with: "const")
        return s
    }

    /// Install a minimal global API surface mirroring the subset of SceneScript that scripts in the corpus actually use.
    /// `nonisolated`: runs on the engine's worker queue (or the parser's evaluator), never on the MainActor.
    nonisolated fileprivate static func installSandbox(in context: JSContext) {
        let console = JSValue(newObjectIn: context)!
        let log: @convention(block) (JSValue) -> Void = { _ in }
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let engine = JSValue(newObjectIn: context)!
        let getTimeOfDay: @convention(block) () -> Double = {
            let date = Date()
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute, .second], from: date)
            let secs = Double((comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0))
            return secs / 86_400.0
        }
        engine.setObject(getTimeOfDay, forKeyedSubscript: "getTimeOfDay" as NSString)
        let getProperty: @convention(block) (String) -> JSValue? = { _ in
            JSValue(undefinedIn: context)
        }
        let setProperty: @convention(block) (String, JSValue) -> Void = { _, _ in }
        engine.setObject(getProperty, forKeyedSubscript: "getPropertyValue" as NSString)
        engine.setObject(setProperty, forKeyedSubscript: "setPropertyValue" as NSString)
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)

        let storage = JSValue(newObjectIn: context)!
        let storageBacking = NSMutableDictionary()
        let storageGet: @convention(block) (String) -> JSValue? = { key in
            storageBacking[key].flatMap { JSValue(object: $0, in: context) }
                ?? JSValue(undefinedIn: context)
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { key, value in
            if value.isString {
                storageBacking[key] = value.toString() ?? ""
            } else if value.isNumber {
                storageBacking[key] = value.toDouble()
            } else if value.isBoolean {
                storageBacking[key] = value.toBool()
            } else {
                storageBacking[key] = value.toObject() ?? NSNull()
            }
        }
        storage.setObject(storageGet, forKeyedSubscript: "get" as NSString)
        storage.setObject(storageSet, forKeyedSubscript: "set" as NSString)
        context.setObject(storage, forKeyedSubscript: "localstorage" as NSString)

        let createScriptProperties: @convention(block) () -> JSValue = {
            let proxy = JSValue(newObjectIn: context)!
            // Each `add*({ name, value, ... })` registers a script property; expose
            // its default `value` on the returned object so `scriptProperties.<name>`
            // resolves (e.g. a clock's `delimiter` → ":" instead of `undefined`,
            // which otherwise stringifies into the rendered text). Returns the proxy
            // so the builder calls chain; `finish()` (no args) just returns it.
            let register: @convention(block) (JSValue) -> JSValue = { config in
                guard config.isObject,
                      let nameValue = config.objectForKeyedSubscript("name"),
                      nameValue.isString, let name = nameValue.toString(), !name.isEmpty else {
                    return proxy
                }
                // Explicit default (addCheckbox/addText/addSlider/addColor).
                if let value = config.objectForKeyedSubscript("value"), !value.isUndefined {
                    proxy.setObject(value, forKeyedSubscript: name as NSString)
                    return proxy
                }
                // `addCombo` carries no top-level `value`; WPE defaults a combo to
                // its FIRST option's value. Without this the combo resolves to
                // `undefined`, so date/clock scripts that branch on it (e.g.
                // `if (scriptProperties.monthFormat == 1)`) take no branch and then
                // throw on `months[...]`/`day[...]` → the text silently reverts to
                // its placeholder. Mirror WPE: fall back to options[0].value.
                if let options = config.objectForKeyedSubscript("options"), options.isArray,
                   let first = options.atIndex(0), first.isObject,
                   let optionValue = first.objectForKeyedSubscript("value"), !optionValue.isUndefined {
                    proxy.setObject(optionValue, forKeyedSubscript: name as NSString)
                }
                return proxy
            }
            for name in ["addCheckbox", "addText", "addSlider", "addColor",
                         "addCombo", "addFile", "addUserShortcut", "addGroup", "finish"] {
                proxy.setObject(register, forKeyedSubscript: name as NSString)
            }
            return proxy
        }
        context.setObject(createScriptProperties, forKeyedSubscript: "createScriptProperties" as NSString)
    }
}

enum WPESceneScriptError: Error, Equatable {
    case contextUnavailable
    /// The script exceeded its wall-clock execution budget (runaway loop);
    /// the instance was disabled before it could hang the render thread.
    case executionTimedOut
}

extension WPESceneScriptPropertyValue {
    /// The bridged value to assign onto the JS `scriptProperties` object.
    var jsBridged: Any {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value
        case .string(let value): return value
        }
    }
}

// MARK: - Shared scriptProperties injection (transform + text-content scripts)

/// Force `let/const scriptProperties` → `var` (after `export` stripping) so the
/// global is a reassignable property of the global object. JavaScriptCore keeps
/// `let`/`const` as lexical bindings OFF the global object, which Swift can
/// neither read nor replace — so the scene's overrides would be ignored.
fileprivate func wpeNormalizeScriptPropertiesDeclaration(_ preprocessed: String) -> String {
    preprocessed
        .replacingOccurrences(of: "let scriptProperties", with: "var scriptProperties")
        .replacingOccurrences(of: "const scriptProperties", with: "var scriptProperties")
}

/// Snapshot a script's declared scriptProperty defaults (from its
/// `createScriptProperties()` object) so an injection can rebuild from them.
fileprivate func wpeDeclaredScriptPropertyDefaults(
    _ value: JSValue?
) -> [String: WPESceneScriptPropertyValue] {
    guard let dict = value?.toDictionary() as? [String: Any] else { return [:] }
    var defaults: [String: WPESceneScriptPropertyValue] = [:]
    for (name, raw) in dict {
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

/// Install a FRESH `scriptProperties` = declared defaults overlaid with the
/// scene's overrides as the script's global, so `update()` reads the scene's
/// configuration. A fresh object means no prior object's bindings leak in, and a
/// script that never declared the object still receives its overrides.
fileprivate func wpeInstallScriptProperties(
    overrides: [String: WPESceneScriptPropertyValue],
    declaredDefaults: [String: WPESceneScriptPropertyValue],
    into context: JSContext
) {
    guard let scriptProperties = JSValue(newObjectIn: context) else { return }
    for (name, value) in declaredDefaults {
        scriptProperties.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
    }
    for (name, value) in overrides {
        scriptProperties.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
    }
    context.setObject(scriptProperties, forKeyedSubscript: "scriptProperties" as NSString)
}

/// Resolves STATIC WPE transform scripts (object `origin`/`scale`) once at parse
/// time so script-driven positions reflect the CURRENT user-property values
/// instead of the stale baked `value`.
///
/// WPE binds e.g. `origin = scriptProperties.{x,y} * engine.canvasSize.{x,y}`,
/// where `scriptProperties` is bound to user sliders. The editor bakes a `value`
/// vec3 from whatever the sliders were last set to; after the user tweaks them,
/// every scripted object keeps sitting at that out-of-date anchor — scene
/// 3660962877's clock/date text "全部挤在一起". Running the real script reproduces
/// WPE exactly for ANY origin script, with no pattern hardcoded.
///
/// Static only: scripts that read time/audio/random are skipped (the caller keeps
/// the baked value) — those need a per-frame tick and live input, a separate
/// feature. One `JSContext` is reused per unique source, so a scene with 67
/// identical origin scripts pays for a single context evaluated once.
///
/// Untrusted input safety: scene packages are community content, so a scripted
/// `origin` could carry a runaway loop. Every evaluation runs on a dedicated
/// serial queue while the parser waits with a wall-clock budget (mirroring
/// `WPESceneScriptInstance`); a single timeout poisons the evaluator so the
/// remaining objects fall back to their baked values and the parse still
/// finishes. The cached-context count is also capped so a scene with hundreds of
/// distinct inline scripts can't exhaust memory at parse time.
///
/// `@unchecked Sendable`: every `JSContext`/`JSValue` and the exception flag are
/// only ever touched on `queue`, the poison state is lock-guarded, and the parser
/// side exchanges value types. (In practice `resolveVec3` is called serially from
/// one parse task.)
final class WPETransformScriptEvaluator: @unchecked Sendable {
    private let canvasSize: SIMD2<Double>
    private let evaluationBudget: TimeInterval
    private let queue = DispatchQueue(
        label: "com.livewallpaper.wpe-transform-evaluator",
        qos: .userInitiated
    )
    private var contextsBySource: [String: CachedContext] = [:]
    /// Set by each context's exception handler; reset around eval/update so a
    /// throwing script is rejected (nil → caller keeps the baked value) instead
    /// of returning a half-mutated input object.
    private let exception = ExceptionFlag()
    /// Guards `poisoned` so the `@unchecked Sendable` claim holds even if a future
    /// caller invokes `resolveVec3` off more than one thread.
    private let poisonLock = NSLock()
    /// Flipped after a single evaluation overruns its budget; the hung worker
    /// still owns `queue`, so every later call must short-circuit to the baked value.
    private var poisoned = false

    /// Upper bound on distinct script contexts built per document. Real scenes
    /// reuse one source across all scripted objects; this only guards pathological
    /// inputs. Beyond it, objects keep their baked value (no crash, no blowup).
    private static let maxCachedContexts = 64

    private final class ExceptionFlag { var didThrow = false }
    private final class ResultBox: @unchecked Sendable { var value: SIMD3<Double>? }

    /// A reused context plus the script's OWN declared scriptProperty defaults,
    /// captured once. Each evaluation rebuilds a fresh `scriptProperties` from
    /// these defaults + the object's overrides, so one object's bindings never
    /// leak into the next object that shares the same cached context.
    private struct CachedContext {
        let context: JSContext
        let declaredDefaults: [String: WPESceneScriptPropertyValue]
    }

    private var isPoisoned: Bool {
        poisonLock.lock(); defer { poisonLock.unlock() }
        return poisoned
    }

    private func poison() {
        poisonLock.lock(); poisoned = true; poisonLock.unlock()
    }

    /// Markers that make a transform script time/audio/random-driven and thus not
    /// statically resolvable. Conservative: a false "dynamic" only leaves the
    /// baked value untouched (no regression). Matching is CASE-SENSITIVE on
    /// purpose — `update` contains a lowercase "date", so a case-insensitive
    /// `Date` check would wrongly classify every origin script as dynamic.
    private static let dynamicTokens = [
        "getTimeOfDay", "frametime", "frameTime", "getTime", "Date",
        "Math.random", "getFrequency", "getFrequencies", "audio", "elapsed"
    ]

    /// `evaluationBudget` covers the first call's cold context bootstrap
    /// (installSandbox + base classes + module eval) plus `update()`, so it is
    /// generous enough never to falsely time out a legitimate script while still
    /// bounding a runaway loop. Matches `WPESceneScriptInstance`'s tick budget.
    init(canvasWidth: Double, canvasHeight: Double, evaluationBudget: TimeInterval = 0.5) {
        self.canvasSize = SIMD2<Double>(canvasWidth, canvasHeight)
        self.evaluationBudget = evaluationBudget
    }

    static func isStaticallyResolvable(_ script: String) -> Bool {
        !dynamicTokens.contains { script.contains($0) }
    }

    /// Returns the script-computed vec3, or nil if the script is dynamic, fails to
    /// evaluate, or overruns its budget (caller keeps the baked value). `seed` is
    /// the baked origin so components the script leaves untouched (z) pass through.
    func resolveVec3(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>
    ) -> SIMD3<Double>? {
        guard !isPoisoned, Self.isStaticallyResolvable(script) else { return nil }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            box.value = evaluateOnQueue(script: script, properties: properties, seed: seed)
            done.signal()
        }
        guard done.wait(timeout: .now() + evaluationBudget) == .success else {
            // Runaway script: the worker is still spinning on `queue`. Stop using
            // it so the parse completes; the rest of the scene keeps baked values.
            poison()
            return nil
        }
        return box.value
    }

    private func evaluateOnQueue(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>
    ) -> SIMD3<Double>? {
        guard let cached = context(for: script) else { return nil }
        let context = cached.context

        // Rebuild a fresh `scriptProperties` from this object's bindings each call.
        exception.didThrow = false
        wpeInstallScriptProperties(
            overrides: properties,
            declaredDefaults: cached.declaredDefaults,
            into: context
        )
        guard !exception.didThrow else { return nil }

        guard let update = context.objectForKeyedSubscript("update"),
              !update.isUndefined, update.hasProperty("call"),
              let valueObject = JSValue(newObjectIn: context) else { return nil }
        valueObject.setObject(seed.x, forKeyedSubscript: "x" as NSString)
        valueObject.setObject(seed.y, forKeyedSubscript: "y" as NSString)
        valueObject.setObject(seed.z, forKeyedSubscript: "z" as NSString)

        exception.didThrow = false
        guard let result = update.call(withArguments: [valueObject]),
              !exception.didThrow,
              !result.isUndefined, !result.isNull, result.isObject,
              let xValue = result.objectForKeyedSubscript("x"),
              let yValue = result.objectForKeyedSubscript("y") else {
            return nil
        }
        let x = xValue.toDouble()
        let y = yValue.toDouble()
        guard x.isFinite, y.isFinite else { return nil }
        let z = result.objectForKeyedSubscript("z")?.toDouble() ?? seed.z
        return SIMD3<Double>(x, y, z.isFinite ? z : seed.z)
    }

    /// Builds (or returns a cached) context for `source`. MUST run on `queue`.
    private func context(for source: String) -> CachedContext? {
        if let cached = contextsBySource[source] { return cached }
        guard contextsBySource.count < Self.maxCachedContexts,
              let context = JSContext() else { return nil }
        WPESceneScriptInstance.installSandbox(in: context)
        WPESceneScriptBaseclasses.install(in: context)
        installCanvasSize(in: context)
        // Install the handler only after bootstrap so it tracks the user script's
        // own exceptions, not any (ignored) noise from the sandbox/base classes.
        context.exceptionHandler = { [exception] _, _ in exception.didThrow = true }
        exception.didThrow = false
        let prepared = wpeNormalizeScriptPropertiesDeclaration(
            WPESceneScriptInstance.preprocess(script: source)
        )
        _ = context.evaluateScript(prepared)
        // A module body that throws at setup never declares a usable update().
        guard !exception.didThrow else { return nil }
        let cached = CachedContext(
            context: context,
            declaredDefaults: wpeDeclaredScriptPropertyDefaults(
                context.objectForKeyedSubscript("scriptProperties")
            )
        )
        contextsBySource[source] = cached
        return cached
    }

    private func installCanvasSize(in context: JSContext) {
        guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
              let size = JSValue(newObjectIn: context) else { return }
        size.setObject(canvasSize.x, forKeyedSubscript: "x" as NSString)
        size.setObject(canvasSize.y, forKeyedSubscript: "y" as NSString)
        engine.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
    }
}
#endif
