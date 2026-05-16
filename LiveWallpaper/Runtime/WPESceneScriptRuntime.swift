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
@MainActor
final class WPESceneScriptInstance {
    private let context: JSContext
    private let updateFunction: JSValue?
    private let initialValue: JSValue
    private(set) var lastValue: String

    /// `script` is the JS source captured from `text: { script: ... }`
    /// (or any other scripted field). `initialValue` seeds the first
    /// `update(value)` call — WPE's convention is that the script
    /// receives the current value and returns the new one.
    init(script: String, initialValue: String) throws {
        guard let context = JSContext() else {
            throw WPESceneScriptError.contextUnavailable
        }
        self.context = context
        self.initialValue = JSValue(object: initialValue, in: context) ?? JSValue(nullIn: context)!
        self.lastValue = initialValue

        Self.installSandbox(in: context)
        let prepared = Self.preprocess(script: script)
        context.exceptionHandler = { _, ex in
            // Suppress noisy console output; surface via `lastError`
            // for callers that want to log it once.
            _ = ex
        }
        let _ = context.evaluateScript(prepared)

        // After evaluation, look up the `update` symbol the WPE convention
        // expects. Some scripts only define `init` (run once at load) so
        // we tolerate `update` being absent.
        let updateValue = context.objectForKeyedSubscript("update")
        if let updateValue, !updateValue.isUndefined, updateValue.hasProperty("call") {
            self.updateFunction = updateValue
        } else {
            self.updateFunction = nil
        }
        // Run init() if defined so the script's one-time setup
        // (storage reads, default state) executes once at load.
        if let initFn = context.objectForKeyedSubscript("init"),
           !initFn.isUndefined, initFn.hasProperty("call") {
            _ = initFn.call(withArguments: [])
        }
    }

    /// Tick the script's `update(value)` and return the latest value as
    /// a String. Falls back to the previous value on script error or
    /// when no `update` is defined.
    func tickString() -> String {
        guard let updateFunction else { return lastValue }
        let arg = JSValue(object: lastValue, in: context) ?? initialValue
        guard let result = updateFunction.call(withArguments: [arg as Any]),
              !result.isUndefined && !result.isNull else {
            return lastValue
        }
        if result.isString, let s = result.toString() {
            lastValue = s
            return s
        }
        // WPE clock scripts sometimes return a number; coerce to string.
        if result.isNumber {
            let s = String(result.toDouble())
            lastValue = s
            return s
        }
        return lastValue
    }

    /// Strip `export` keywords + `'use strict'` so the script body
    /// evaluates as flat top-level declarations the JSContext can
    /// look up by name. ES module scopes aren't available in
    /// JavaScriptCore without manual transformation.
    private static func preprocess(script: String) -> String {
        var s = script
        s = s.replacingOccurrences(of: "'use strict';", with: "")
        s = s.replacingOccurrences(of: "\"use strict\";", with: "")
        // Replace `export function foo` with `function foo` so the
        // function lands at global scope where we can look it up.
        s = s.replacingOccurrences(of: "export function", with: "function")
        s = s.replacingOccurrences(of: "export var", with: "var")
        s = s.replacingOccurrences(of: "export let", with: "let")
        s = s.replacingOccurrences(of: "export const", with: "const")
        return s
    }

    /// Install a minimal global API surface mirroring the subset of
    /// SceneScript that scripts in the corpus actually use. Anything
    /// not declared here resolves to undefined.
    private static func installSandbox(in context: JSContext) {
        // `console.log` for script-author diagnostics; no-op so we
        // don't pollute Xcode's debug pane during corpus scans.
        let console = JSValue(newObjectIn: context)!
        let log: @convention(block) (JSValue) -> Void = { _ in }
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        // `engine.getTimeOfDay()` returns the fraction of the day
        // (0..1) — corpus clock scripts use this for sun-rise tints.
        let engine = JSValue(newObjectIn: context)!
        let getTimeOfDay: @convention(block) () -> Double = {
            let date = Date()
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute, .second], from: date)
            let secs = Double((comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0))
            return secs / 86_400.0
        }
        engine.setObject(getTimeOfDay, forKeyedSubscript: "getTimeOfDay" as NSString)
        // `engine.getPropertyValue` and `setPropertyValue` are no-ops
        // for now (no UI wiring yet); they return undefined so script
        // code that reads a property gets a falsy value and continues.
        let getProperty: @convention(block) (String) -> JSValue? = { _ in
            JSValue(undefinedIn: context)
        }
        let setProperty: @convention(block) (String, JSValue) -> Void = { _, _ in }
        engine.setObject(getProperty, forKeyedSubscript: "getPropertyValue" as NSString)
        engine.setObject(setProperty, forKeyedSubscript: "setPropertyValue" as NSString)
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)

        // `localstorage` stub backed by an in-context dictionary so
        // scripts that persist drag positions etc. don't crash. State
        // is per-scene-instance which is fine for read/write within
        // one playthrough.
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

        // Global `createScriptProperties` chainable stub: corpus scripts
        // call `.addCheckbox(...).addText(...).finish()` to declare UI
        // properties. We hand back an empty object that returns itself
        // from every method so the chain doesn't throw.
        let createScriptProperties: @convention(block) () -> JSValue = {
            let proxy = JSValue(newObjectIn: context)!
            // Self-returning chainable methods; `finish()` returns the
            // proxy itself which scripts use as the property bag.
            let chainable: @convention(block) (JSValue) -> JSValue = { _ in proxy }
            for name in ["addCheckbox", "addText", "addSlider", "addColor",
                         "addCombo", "addFile", "addUserShortcut", "addGroup", "finish"] {
                proxy.setObject(chainable, forKeyedSubscript: name as NSString)
            }
            return proxy
        }
        context.setObject(createScriptProperties, forKeyedSubscript: "createScriptProperties" as NSString)
    }
}

enum WPESceneScriptError: Error, Equatable {
    case contextUnavailable
}
#endif
