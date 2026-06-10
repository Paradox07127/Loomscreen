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
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5
    ) throws {
        self.lastValue = initialValue
        self.tickBudget = tickBudget
        self.engine = Engine()
        let prepared = Self.preprocess(script: script)
        guard let outcome = engine.setUp(script: prepared, budget: setupBudget) else {
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
        func setUp(script: String, budget: TimeInterval) -> SetupOutcome? {
            runWithBudget(budget) { self.setUpOnQueue(script: script) }
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

        private func setUpOnQueue(script: String) -> SetupOutcome {
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
    private static func preprocess(script: String) -> String {
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
    /// `nonisolated`: runs on the engine's worker queue, never on the MainActor.
    nonisolated private static func installSandbox(in context: JSContext) {
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
#endif
