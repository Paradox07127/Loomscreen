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

    /// `script` is the JS source captured from `text: { script: ...
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
            _ = ex
        }
        let _ = context.evaluateScript(prepared)

        let updateValue = context.objectForKeyedSubscript("update")
        if let updateValue, !updateValue.isUndefined, updateValue.hasProperty("call") {
            self.updateFunction = updateValue
        } else {
            self.updateFunction = nil
        }
        if let initFn = context.objectForKeyedSubscript("init"),
           !initFn.isUndefined, initFn.hasProperty("call") {
            _ = initFn.call(withArguments: [])
        }
    }

    /// Tick the script's `update(value)` and return the latest value as a String.
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
        if result.isNumber {
            let s = String(result.toDouble())
            lastValue = s
            return s
        }
        return lastValue
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
    private static func installSandbox(in context: JSContext) {
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
