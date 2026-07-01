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

    /// Budgets: setup covers the whole module body + `init()` (allow real
    /// work); per-frame `update()` is expected to be microseconds, so an
    /// overrun only ever means a runaway loop. Tests inject smaller values.
    init(
        script: String,
        initialValue: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5
    ) throws {
        self.lastValue = initialValue
        self.tickBudget = tickBudget
        self.engine = Engine(shared: shared)
        var prepared = Self.preprocess(script: script)
        // Normalize `let/const scriptProperties` → `var` only when injecting, so
        // the scene's overrides reach a reassignable global.
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
        private let shared: WPESharedScriptState?

        init(shared: WPESharedScriptState?) {
            self.shared = shared
        }

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
            if let shared { wpeInstallSharedState(shared, in: context) }
            context.exceptionHandler = { _, ex in
                _ = ex
            }
            let _ = context.evaluateScript(script)

            // Overlay the scene's per-object scriptProperty overrides onto the
            // script's declared defaults, so text renders with the scene's
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
        // WPE serializes some exported scripts with non-breaking spaces between
        // keywords (`export function`), which JavaScriptCore will not match via
        // the ASCII-space replacements below.
        for space in ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{FEFF}"] {
            s = s.replacingOccurrences(of: space, with: " ")
        }
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
        let getFrequency: @convention(block) (Int) -> Double = { _ in 0 }
        let getFrequencies: @convention(block) () -> JSValue = {
            JSValue(object: [Double](repeating: 0, count: 64), in: context)
                ?? JSValue(newArrayIn: context)!
        }
        let registerAudioBuffers: @convention(block) (Int) -> JSValue = { requestedBands in
            let bands = min(max(requestedBands, 0), 256)
            let buffer = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let average = JSValue(object: [Double](repeating: 0, count: bands), in: context)
                ?? JSValue(newArrayIn: context)!
            buffer.setObject(
                average,
                forKeyedSubscript: "average" as NSString
            )
            return buffer
        }
        engine.setObject(getFrequency, forKeyedSubscript: "getFrequency" as NSString)
        engine.setObject(getFrequencies, forKeyedSubscript: "getFrequencies" as NSString)
        engine.setObject(registerAudioBuffers, forKeyedSubscript: "registerAudioBuffers" as NSString)
        let screenResolution = JSValue(newObjectIn: context)!
        screenResolution.setObject(1920.0, forKeyedSubscript: "x" as NSString)
        screenResolution.setObject(1080.0, forKeyedSubscript: "y" as NSString)
        engine.setObject(screenResolution, forKeyedSubscript: "screenResolution" as NSString)
        engine.setObject(screenResolution, forKeyedSubscript: "canvasSize" as NSString)
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)

        let input = JSValue(newObjectIn: context)!
        let cursorScreen = JSValue(newObjectIn: context)!
        cursorScreen.setObject(960.0, forKeyedSubscript: "x" as NSString)
        cursorScreen.setObject(540.0, forKeyedSubscript: "y" as NSString)
        input.setObject(cursorScreen, forKeyedSubscript: "cursorScreenPosition" as NSString)
        input.setObject(cursorScreen, forKeyedSubscript: "cursorWorldPosition" as NSString)
        context.setObject(input, forKeyedSubscript: "input" as NSString)

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

// MARK: - Layer SceneScript (visible-script video intros)

/// One playback command a layer script issued via `thisLayer.getVideoTexture()`.
enum WPELayerVideoCommand: Sendable, Equatable {
    case play
    case pause
    case stop
    case seek(TimeInterval)
}

/// The observable result of running a layer SceneScript's `init()`/`update()`:
/// the script's resolved `thisLayer.visible`/`alpha`, plus the video commands it
/// issued this run (drained each time). Pure value type so it crosses the
/// engine-queue → MainActor boundary safely.
struct WPELayerScriptState: Sendable, Equatable {
    var visible: Bool
    var alpha: Double
    var videoCommands: [WPELayerVideoCommand]
}

/// Runtime state for a layer created by `thisScene.createLayer(...)`.
/// These handles are authored dynamically by SceneScript, so they are surfaced
/// separately from graph-backed `thisLayer` / `getLayer(name)` state.
struct WPECreatedLayerScriptState: Sendable, Equatable {
    var key: String
    var imagePath: String
    var origin: SIMD3<Double>
    var color: SIMD3<Double>
    var scale: SIMD3<Double>
    var alpha: Double
    var visible: Bool
}

/// A layer script's full output for one run: state for its own layer (`thisLayer`)
/// plus state for any other layers it reached via `thisScene.getLayer(name)`
/// (keyed by layer name). The renderer resolves the names to objectIDs.
struct WPELayerScriptOutput: Sendable, Equatable {
    var own: WPELayerScriptState
    var others: [String: WPELayerScriptState]
    var created: [WPECreatedLayerScriptState] = []
}

enum WPELayerScriptOutputMode: Sendable, Equatable {
    case layerState
    case returnedAlpha(initialValue: Double)
}

enum WPELayerScriptCursorEvent: Sendable, Equatable {
    case down
    case up
    case rightDown
    case rightUp

    fileprivate var handlerName: String {
        switch self {
        case .down: return "cursorDown"
        case .up: return "cursorUp"
        case .rightDown: return "cursorRightDown"
        case .rightUp: return "cursorRightUp"
        }
    }
}

/// Runs a WPE SceneScript attached to an image layer's `visible` field — a JS
/// program whose `init()`/`update()` drive the layer's visibility/alpha and its
/// video texture (`thisLayer.getVideoTexture().play()/stop()/…`). Unlike
/// `WPESceneScriptInstance` (which consumes a returned text string), this reads
/// the script's mutations to `thisLayer` back after each tick and surfaces the
/// buffered video commands so the renderer can apply them.
///
/// Same containment model as `WPESceneScriptInstance`: each script owns a
/// JSContext on a dedicated serial queue, every evaluation is wall-clock
/// budgeted, and an overrun poisons the instance (frozen at its last state)
/// rather than hanging the render thread.
@MainActor
final class WPELayerScriptInstance {
    private let engine: LayerEngine
    private let hasUpdateFunction: Bool
    private let tickBudget: TimeInterval
    private var isPoisoned = false
    let initialOutput: WPELayerScriptOutput

    private static var quarantine: [LayerEngine] = []

    init(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        canvasSize: SIMD2<Double> = SIMD2<Double>(1920, 1080),
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        nowProviderMillis: (@Sendable () -> Double)? = nil,
        outputMode: WPELayerScriptOutputMode = .layerState
    ) throws {
        self.tickBudget = tickBudget
        let engine = LayerEngine(
            nowProviderMillis: nowProviderMillis,
            shared: shared,
            canvasSize: canvasSize,
            outputMode: outputMode
        )
        self.engine = engine
        var prepared = WPESceneScriptInstance.preprocess(script: script)
        // Strip ESM `import` lines (e.g. `import * as WEMath from 'WEMath';`) —
        // a top-level `import` is a SyntaxError in JSContext's non-module eval,
        // which would otherwise abort the whole module and leave no init/update.
        prepared = prepared.replacingOccurrences(
            of: "(?m)^[\\t ]*import\\b[^\\n]*$",
            with: "",
            options: .regularExpression
        )
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
            Logger.warning("Layer SceneScript setup exceeded \(setupBudget)s — script disabled", category: .wpeRender)
            throw WPESceneScriptError.executionTimedOut
        }
        switch outcome {
        case .contextUnavailable:
            throw WPESceneScriptError.contextUnavailable
        case .ready(let hasUpdate, let output):
            self.hasUpdateFunction = hasUpdate
            self.initialOutput = output
        }
    }

    /// Tick `update()`; returns the script's new per-layer output, or nil when
    /// there's no `update()` or the instance is poisoned/timed out.
    func tick(runtimeSeconds: Double? = nil, pointerFrame: WPEPointerFrame? = nil) -> WPELayerScriptOutput? {
        guard hasUpdateFunction, !isPoisoned else { return nil }
        guard let output = engine.tick(
            runtimeSeconds: runtimeSeconds,
            pointerFrame: pointerFrame,
            budget: tickBudget
        ) else {
            isPoisoned = true
            Self.quarantine.append(engine)
            Logger.warning("Layer SceneScript update() exceeded \(tickBudget)s — frozen", category: .wpeRender)
            return nil
        }
        return output
    }

    @discardableResult
    func dispatchCursorEvent(
        _ event: WPELayerScriptCursorEvent,
        pointerFrame: WPEPointerFrame,
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned else { return nil }
        guard let output = engine.dispatchCursorEvent(
            event,
            pointerFrame: pointerFrame,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) else {
            isPoisoned = true
            Self.quarantine.append(engine)
            Logger.warning("Layer SceneScript \(event.handlerName)() exceeded \(tickBudget)s — frozen", category: .wpeRender)
            return nil
        }
        return output
    }

    /// Invoke the script's `applyUserProperties(changedUserProperties)` with the
    /// scene's user-property values. Time-of-day scripts gate their day/night
    /// switch on a flag set ONLY here (e.g. `timevarying`), so without this the
    /// switch never activates. Returns the resulting layer output (the unchanged
    /// current state when the script declares no such handler); nil only when
    /// poisoned, timed out, or given no properties.
    @discardableResult
    func applyUserProperties(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !properties.isEmpty else { return nil }
        guard let output = engine.applyUserProperties(
            properties,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) else {
            isPoisoned = true
            Self.quarantine.append(engine)
            Logger.warning("Layer SceneScript applyUserProperties() exceeded \(tickBudget)s — frozen", category: .wpeRender)
            return nil
        }
        return output
    }

    private final class LayerEngine: @unchecked Sendable {
        enum SetupOutcome {
            case ready(hasUpdate: Bool, output: WPELayerScriptOutput)
            case contextUnavailable
        }

        /// Key for `thisLayer` in the per-layer command/handle maps (other layers
        /// use their `getLayer(name)` name).
        private static let ownKey = ""

        private let queue = DispatchQueue(label: "com.livewallpaper.wpe-layerscript", qos: .userInitiated)
        private var context: JSContext?
        private var updateFunction: JSValue?
        private var thisLayer: JSValue?
        /// Set by the context exception handler so `init()` failures can degrade
        /// safely (run on the engine queue, so no synchronization needed).
        private var didThrow = false
        /// Handles minted by `thisScene.getLayer(name)`, keyed by layer name.
        private var namedLayers: [String: JSValue] = [:]
        private var createdLayers: [(key: String, handle: JSValue)] = []
        private var createdLayerCounter = 0
        /// Video commands per layer key ("" = thisLayer, else the getLayer name).
        /// Drained on the engine queue (where the JS blocks also append) so there
        /// is no cross-thread race.
        private var pendingVideo: [String: [WPELayerVideoCommand]] = [:]
        private let nowProviderMillis: (@Sendable () -> Double)?
        private let shared: WPESharedScriptState?
        private let canvasSize: SIMD2<Double>
        private let outputMode: WPELayerScriptOutputMode
        private var returnedAlphaValue: Double
        private var lastRuntimeSeconds: Double?
        private var cursorScreenPosition: JSValue?
        private var cursorWorldPosition: JSValue?
        /// Reused per-context stubs for `getParent()` / `getAnimationLayer()` so a
        /// chain (`getParent().getParent()`) doesn't mint a fresh object each call.
        private var neutralLayerStubCache: JSValue?
        private var neutralAnimationStubCache: JSValue?

        init(
            nowProviderMillis: (@Sendable () -> Double)?,
            shared: WPESharedScriptState?,
            canvasSize: SIMD2<Double>,
            outputMode: WPELayerScriptOutputMode
        ) {
            self.nowProviderMillis = nowProviderMillis
            self.shared = shared
            self.canvasSize = SIMD2<Double>(max(canvasSize.x, 1), max(canvasSize.y, 1))
            self.outputMode = outputMode
            switch outputMode {
            case .layerState:
                self.returnedAlphaValue = 1
            case .returnedAlpha(let initialValue):
                self.returnedAlphaValue = initialValue.isFinite ? initialValue : 1
            }
        }

        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            budget: TimeInterval
        ) -> SetupOutcome? {
            runWithBudget(budget) { self.setUpOnQueue(script: script, scriptProperties: scriptProperties) }
        }

        func tick(
            runtimeSeconds: Double?,
            pointerFrame: WPEPointerFrame?,
            budget: TimeInterval
        ) -> WPELayerScriptOutput? {
            runWithBudget(budget) {
                self.tickOnQueue(runtimeSeconds: runtimeSeconds, pointerFrame: pointerFrame)
            }
        }

        func dispatchCursorEvent(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPELayerScriptOutput? {
            runWithBudget(budget) {
                self.dispatchCursorEventOnQueue(
                    event,
                    pointerFrame: pointerFrame,
                    runtimeSeconds: runtimeSeconds
                )
            }
        }

        func applyUserProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPELayerScriptOutput? {
            runWithBudget(budget) {
                self.applyUserPropertiesOnQueue(properties, runtimeSeconds: runtimeSeconds)
            }
        }

        private func runWithBudget<T>(_ budget: TimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
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
            guard let context = JSContext() else { return .contextUnavailable }
            self.context = context
            WPESceneScriptInstance.installSandbox(in: context)
            WPESceneScriptBaseclasses.install(in: context)
            installCanvasSize(in: context)
            installInput(in: context)
            updateEngineRuntime(0)
            installLayerBridge(in: context)
            if case .returnedAlpha = outputMode {
                setOwnLayerAlpha(returnedAlphaValue)
            }
            if let shared { wpeInstallSharedState(shared, in: context) }
            if let nowProviderMillis {
                let now: @convention(block) () -> Double = { nowProviderMillis() }
                context.setObject(now, forKeyedSubscript: "__hostNow" as NSString)
                _ = context.evaluateScript("Date.now = function(){ return __hostNow(); };")
            }
            context.exceptionHandler = { [weak self] _, _ in self?.didThrow = true }
            _ = context.evaluateScript(script)
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
            pendingVideo.removeAll(keepingCapacity: true)
            didThrow = false
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                _ = initFn.call(withArguments: [])
            }
            // A script that throws in init() (e.g. an API we don't yet support)
            // must NOT half-apply — degrade to "shown as authored" so a broken
            // script can't hide its layer, and don't tick its update().
            if didThrow {
                return .ready(hasUpdate: false, output: WPELayerScriptOutput(
                    own: WPELayerScriptState(visible: true, alpha: 1, videoCommands: []),
                    others: [:]
                ))
            }
            return .ready(hasUpdate: updateFunction != nil, output: readOutput())
        }

        private func tickOnQueue(
            runtimeSeconds: Double?,
            pointerFrame: WPEPointerFrame?
        ) -> WPELayerScriptOutput {
            updateEngineRuntime(runtimeSeconds)
            updateInput(pointerFrame)
            guard let context, let updateFunction else {
                return WPELayerScriptOutput(own: .init(visible: true, alpha: 1, videoCommands: []), others: [:])
            }
            pendingVideo.removeAll(keepingCapacity: true)
            switch outputMode {
            case .layerState:
                _ = updateFunction.call(withArguments: [])
            case .returnedAlpha:
                let arg = JSValue(object: returnedAlphaValue, in: context) ?? JSValue(nullIn: context)!
                if let result = updateFunction.call(withArguments: [arg as Any]),
                   !result.isUndefined, !result.isNull, result.isNumber {
                    let value = result.toDouble()
                    if value.isFinite {
                        returnedAlphaValue = value
                        setOwnLayerAlpha(value)
                    }
                }
            }
            return readOutput()
        }

        private func dispatchCursorEventOnQueue(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            updateEngineRuntime(runtimeSeconds)
            updateInput(pointerFrame)
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else {
                return readOutput()
            }
            pendingVideo.removeAll(keepingCapacity: true)
            _ = fn.call(withArguments: [cursorEventObject(event, pointerFrame: pointerFrame, in: context)])
            return readOutput()
        }

        private func applyUserPropertiesOnQueue(
            _ properties: [String: WPESceneScriptPropertyValue],
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            updateEngineRuntime(runtimeSeconds)
            guard let context,
                  let fn = context.objectForKeyedSubscript("applyUserProperties"),
                  !fn.isUndefined, fn.hasProperty("call"),
                  let bag = JSValue(newObjectIn: context) else {
                return readOutput()
            }
            for (name, value) in properties {
                bag.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
            }
            pendingVideo.removeAll(keepingCapacity: true)
            _ = fn.call(withArguments: [bag])
            return readOutput()
        }

        private func updateEngineRuntime(_ runtimeSeconds: Double?) {
            guard let context,
                  let engine = context.objectForKeyedSubscript("engine"),
                  !engine.isUndefined else { return }
            let runtime = runtimeSeconds.map { $0.isFinite ? $0 : 0 } ?? 0
            let frameTime: Double
            if let previous = lastRuntimeSeconds {
                frameTime = max(runtime - previous, 0)
            } else {
                frameTime = max(runtime, 1.0 / 30.0)
            }
            lastRuntimeSeconds = runtime
            engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
            engine.setObject(frameTime, forKeyedSubscript: "frametime" as NSString)
        }

        private func installCanvasSize(in context: JSContext) {
            guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
                  let size = JSValue(newObjectIn: context) else { return }
            size.setObject(canvasSize.x, forKeyedSubscript: "x" as NSString)
            size.setObject(canvasSize.y, forKeyedSubscript: "y" as NSString)
            engine.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
            engine.setObject(size, forKeyedSubscript: "screenResolution" as NSString)
        }

        private func installInput(in context: JSContext) {
            let input = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let screen = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let world = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            input.setObject(screen, forKeyedSubscript: "cursorScreenPosition" as NSString)
            input.setObject(world, forKeyedSubscript: "cursorWorldPosition" as NSString)
            context.setObject(input, forKeyedSubscript: "input" as NSString)
            cursorScreenPosition = screen
            cursorWorldPosition = world
            updateInput(.neutral)
        }

        private func updateInput(_ pointerFrame: WPEPointerFrame?) {
            guard let pointerFrame else { return }
            let x = clampFinite(pointerFrame.position.x, lower: 0, upper: 1)
            let y = clampFinite(pointerFrame.position.y, lower: 0, upper: 1)
            cursorScreenPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
            cursorScreenPosition?.setObject(y * canvasSize.y, forKeyedSubscript: "y" as NSString)
            cursorWorldPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
            cursorWorldPosition?.setObject((1.0 - y) * canvasSize.y, forKeyedSubscript: "y" as NSString)
            cursorWorldPosition?.setObject(0.0, forKeyedSubscript: "z" as NSString)
        }

        private func cursorEventObject(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            in context: JSContext
        ) -> JSValue {
            let object = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            object.setObject(event.handlerName, forKeyedSubscript: "type" as NSString)
            object.setObject(pointerFrame.isDown, forKeyedSubscript: "leftDown" as NSString)
            object.setObject(pointerFrame.isRightDown, forKeyedSubscript: "rightDown" as NSString)
            let position = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            position.setObject(clampFinite(pointerFrame.position.x, lower: 0, upper: 1), forKeyedSubscript: "x" as NSString)
            position.setObject(clampFinite(pointerFrame.position.y, lower: 0, upper: 1), forKeyedSubscript: "y" as NSString)
            object.setObject(position, forKeyedSubscript: "position" as NSString)
            object.setObject(cursorScreenPosition, forKeyedSubscript: "cursorScreenPosition" as NSString)
            object.setObject(cursorWorldPosition, forKeyedSubscript: "cursorWorldPosition" as NSString)
            return object
        }

        private func clampFinite(_ value: Double, lower: Double, upper: Double) -> Double {
            guard value.isFinite else { return (lower + upper) * 0.5 }
            return min(max(value, lower), upper)
        }

        private func setOwnLayerAlpha(_ value: Double) {
            thisLayer?.setObject(value.isFinite ? value : 1, forKeyedSubscript: "alpha" as NSString)
        }

        /// Installs a real `thisLayer` (the script's own layer), a `thisScene`
        /// whose `getLayer(name)` mints per-name handles (so a button script can
        /// drive another video layer), and a small `WEMath` shim. All replace the
        /// base-class read-only stubs.
        private func installLayerBridge(in context: JSContext) {
            let layer = makeLayerHandle(key: Self.ownKey, in: context)
            context.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
            self.thisLayer = layer

            let getLayer: @convention(block) (JSValue) -> JSValue = { [weak self] nameValue in
                guard let self,
                      nameValue.isString,
                      let name = nameValue.toString(), !name.isEmpty else {
                    return JSValue(nullIn: context)
                }
                if let existing = self.namedLayers[name] { return existing }
                let handle = self.makeLayerHandle(key: name, in: context)
                self.namedLayers[name] = handle
                return handle
            }
            let scene = JSValue(newObjectIn: context)!
            scene.setObject(getLayer, forKeyedSubscript: "getLayer" as NSString)
            let createLayer: @convention(block) (JSValue) -> JSValue = { [weak self] spec in
                guard let self else { return JSValue(nullIn: context) }
                let key = "__created_\(self.createdLayerCounter)"
                let handle = self.makeLayerHandle(key: key, in: context)
                self.createdLayerCounter += 1
                self.createdLayers.append((key, handle))
                if spec.isObject {
                    for property in ["image", "origin", "color", "scale", "alpha", "visible"] {
                        if let value = spec.objectForKeyedSubscript(property), !value.isUndefined {
                            handle.setObject(value, forKeyedSubscript: property as NSString)
                        }
                    }
                }
                return handle
            }
            scene.setObject(createLayer, forKeyedSubscript: "createLayer" as NSString)
            // `scene.on(event, cb)` isn't a real WPE API (some scenes assume it);
            // a no-op stub keeps such a script from throwing at top-level eval.
            let on: @convention(block) (JSValue, JSValue) -> Void = { _, _ in }
            scene.setObject(on, forKeyedSubscript: "on" as NSString)
            context.setObject(scene, forKeyedSubscript: "thisScene" as NSString)
            context.setObject(scene, forKeyedSubscript: "scene" as NSString)

            // Minimal `WEMath` shim — the `import * as WEMath` line is stripped, so
            // the namespace would otherwise be undefined. Covers what intro/button
            // scripts use (linear interpolation + clamping).
            if let weMath = JSValue(newObjectIn: context) {
                let mix: @convention(block) (Double, Double, Double) -> Double = { a, b, t in a + (b - a) * t }
                let clampFn: @convention(block) (Double, Double, Double) -> Double = { x, lo, hi in Swift.min(Swift.max(x, lo), hi) }
                let saturate: @convention(block) (Double) -> Double = { Swift.min(Swift.max($0, 0), 1) }
                weMath.setObject(mix, forKeyedSubscript: "mix" as NSString)
                weMath.setObject(mix, forKeyedSubscript: "lerp" as NSString)
                weMath.setObject(clampFn, forKeyedSubscript: "clamp" as NSString)
                weMath.setObject(saturate, forKeyedSubscript: "saturate" as NSString)
                context.setObject(weMath, forKeyedSubscript: "WEMath" as NSString)
            }
        }

        /// A writable layer handle (visible/alpha + `getVideoTexture()`) tagged
        /// with `key` so its video commands route to the right layer. Also carries
        /// the WPE hierarchy/animation accessors as graceful stubs (we don't model
        /// live parent transforms or animation playback): `scale` reads 1,
        /// `getParent()` returns a neutral ancestor, `getAnimationLayer()` a no-op —
        /// so a UI script that walks the tree runs instead of throwing on init.
        private func makeLayerHandle(key: String, in context: JSContext) -> JSValue {
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            handle.setObject(true, forKeyedSubscript: "visible" as NSString)
            handle.setObject(1.0, forKeyedSubscript: "alpha" as NSString)
            handle.setObject(Self.unitScale(in: context), forKeyedSubscript: "scale" as NSString)
            let videoHandle = makeVideoHandle(key: key, in: context)
            let getVideoTexture: @convention(block) () -> JSValue = { videoHandle }
            handle.setObject(getVideoTexture, forKeyedSubscript: "getVideoTexture" as NSString)
            let parent = neutralLayerStub(in: context)
            let getParent: @convention(block) () -> JSValue = { parent }
            handle.setObject(getParent, forKeyedSubscript: "getParent" as NSString)
            let anim = neutralAnimationStub(in: context)
            let getAnimationLayer: @convention(block) (JSValue) -> JSValue = { _ in anim }
            handle.setObject(getAnimationLayer, forKeyedSubscript: "getAnimationLayer" as NSString)
            return handle
        }

        private static func unitScale(in context: JSContext) -> JSValue {
            let scale = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            scale.setObject(1.0, forKeyedSubscript: "x" as NSString)
            scale.setObject(1.0, forKeyedSubscript: "y" as NSString)
            scale.setObject(1.0, forKeyedSubscript: "z" as NSString)
            return scale
        }

        /// Neutral ancestor for `getParent()`: unit scale, visible, and self-returning
        /// `getParent()` so a `getParent().getParent()` chain terminates safely.
        private func neutralLayerStub(in context: JSContext) -> JSValue {
            if let cached = neutralLayerStubCache { return cached }
            let stub = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            stub.setObject(true, forKeyedSubscript: "visible" as NSString)
            stub.setObject(1.0, forKeyedSubscript: "alpha" as NSString)
            stub.setObject(Self.unitScale(in: context), forKeyedSubscript: "scale" as NSString)
            let getParent: @convention(block) () -> JSValue = { [weak self] in
                self?.neutralLayerStubCache ?? JSValue(undefinedIn: context)
            }
            stub.setObject(getParent, forKeyedSubscript: "getParent" as NSString)
            let anim = neutralAnimationStub(in: context)
            let getAnimationLayer: @convention(block) (JSValue) -> JSValue = { _ in anim }
            stub.setObject(getAnimationLayer, forKeyedSubscript: "getAnimationLayer" as NSString)
            neutralLayerStubCache = stub
            return stub
        }

        private func neutralAnimationStub(in context: JSContext) -> JSValue {
            if let cached = neutralAnimationStubCache { return cached }
            let stub = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let noop: @convention(block) () -> Void = {}
            let noop1: @convention(block) (JSValue) -> Void = { _ in }
            for method in ["play", "pause", "stop"] {
                stub.setObject(noop, forKeyedSubscript: method as NSString)
            }
            stub.setObject(noop1, forKeyedSubscript: "setFrame" as NSString)
            neutralAnimationStubCache = stub
            return stub
        }

        private func makeVideoHandle(key: String, in context: JSContext) -> JSValue {
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let append: @Sendable (WPELayerVideoCommand) -> Void = { [weak self] command in
                self?.pendingVideo[key, default: []].append(command)
            }
            let play: @convention(block) () -> Void = { append(.play) }
            let pause: @convention(block) () -> Void = { append(.pause) }
            let stop: @convention(block) () -> Void = { append(.stop) }
            let setCurrentTime: @convention(block) (JSValue) -> Void = { arg in append(.seek(arg.toDouble())) }
            let getCurrentTime: @convention(block) () -> Double = { 0 }
            handle.setObject(play, forKeyedSubscript: "play" as NSString)
            handle.setObject(pause, forKeyedSubscript: "pause" as NSString)
            handle.setObject(stop, forKeyedSubscript: "stop" as NSString)
            handle.setObject(setCurrentTime, forKeyedSubscript: "setCurrentTime" as NSString)
            handle.setObject(getCurrentTime, forKeyedSubscript: "getCurrentTime" as NSString)
            return handle
        }

        private func readOutput() -> WPELayerScriptOutput {
            let own = stateFor(handle: thisLayer, key: Self.ownKey)
            var others: [String: WPELayerScriptState] = [:]
            for (name, handle) in namedLayers {
                others[name] = stateFor(handle: handle, key: name)
            }
            let created = createdLayers.map { createdStateFor(handle: $0.handle, key: $0.key) }
            pendingVideo.removeAll(keepingCapacity: true)
            return WPELayerScriptOutput(own: own, others: others, created: created)
        }

        private func stateFor(handle: JSValue?, key: String) -> WPELayerScriptState {
            let visible = handle?.objectForKeyedSubscript("visible")?.toBool() ?? true
            let alphaValue = handle?.objectForKeyedSubscript("alpha")
            let alpha = (alphaValue?.isNumber == true) ? (alphaValue?.toDouble() ?? 1) : 1
            return WPELayerScriptState(
                visible: visible,
                alpha: alpha.isFinite ? alpha : 1,
                videoCommands: pendingVideo[key] ?? []
            )
        }

        private func createdStateFor(handle: JSValue, key: String) -> WPECreatedLayerScriptState {
            let imagePath = stringProperty(handle.objectForKeyedSubscript("image"), fallback: "")
            let origin = vec3(
                handle.objectForKeyedSubscript("origin"),
                fallback: SIMD3<Double>(0, 0, 0)
            )
            let color = vec3(
                handle.objectForKeyedSubscript("color"),
                fallback: SIMD3<Double>(1, 1, 1)
            )
            let scale = vec3(
                handle.objectForKeyedSubscript("scale"),
                fallback: SIMD3<Double>(1, 1, 1)
            )
            let alphaValue = handle.objectForKeyedSubscript("alpha")
            let alpha = (alphaValue?.isNumber == true) ? (alphaValue?.toDouble() ?? 1) : 1
            let visible = handle.objectForKeyedSubscript("visible")?.toBool() ?? true
            return WPECreatedLayerScriptState(
                key: key,
                imagePath: imagePath,
                origin: origin,
                color: color,
                scale: scale,
                alpha: alpha.isFinite ? alpha : 1,
                visible: visible
            )
        }

        private func vec3(_ value: JSValue?, fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let value, value.isObject else { return fallback }
            let x = value.objectForKeyedSubscript("x")?.toDouble() ?? fallback.x
            let y = value.objectForKeyedSubscript("y")?.toDouble() ?? fallback.y
            let z = value.objectForKeyedSubscript("z")?.toDouble() ?? fallback.z
            return SIMD3<Double>(
                x.isFinite ? x : fallback.x,
                y.isFinite ? y : fallback.y,
                z.isFinite ? z : fallback.z
            )
        }

        private func stringProperty(_ value: JSValue?, fallback: String) -> String {
            guard let value, !value.isUndefined, !value.isNull else { return fallback }
            return value.toString() ?? fallback
        }

        private final class ResultBox<T>: @unchecked Sendable {
            var value: T?
        }
    }
}

extension WPESceneScriptPropertyValue {
    var jsBridged: Any {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value
        case .string(let value): return value
        }
    }
}

// MARK: - Shared cross-script state (`shared` global)

/// Wallpaper Engine's `shared` global — one object visible to every script in a
/// scene, used for cross-script coordination (e.g. a media-player widget's
/// settings/visibility state). Each script's `JSContext` is isolated, so `shared`
/// can't be one JSValue; it's a host-owned, lock-guarded store that per-context
/// `shared` Proxies read/write. Values cross contexts as primitives.
final class WPESharedScriptState: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, _ value: Any?) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value ?? NSNull()
    }
}

private func wpeBridgeJSValueToHost(_ value: JSValue) -> Any? {
    if value.isBoolean { return value.toBool() }
    if value.isNumber { return value.toDouble() }
    if value.isString { return value.toString() }
    if value.isNull || value.isUndefined { return nil }
    return value.toObject()
}

/// Install `shared` as a Proxy whose traps route to `store`, so every script in
/// the scene reads/writes the same primitives across isolated contexts.
private func wpeInstallSharedState(_ store: WPESharedScriptState, in context: JSContext) {
    let get: @convention(block) (String) -> Any? = { store.get($0) }
    let set: @convention(block) (String, JSValue) -> Void = { key, value in
        store.set(key, wpeBridgeJSValueToHost(value))
    }
    context.setObject(get, forKeyedSubscript: "__sharedGet" as NSString)
    context.setObject(set, forKeyedSubscript: "__sharedSet" as NSString)
    _ = context.evaluateScript("""
    var shared = new Proxy({}, {
        get: function(_t, k) { return __sharedGet(k); },
        set: function(_t, k, v) { __sharedSet(k, v); return true; },
        has: function(_t, k) { return __sharedGet(k) !== undefined; }
    });
    """)
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
        "Math.random", "getFrequency", "getFrequencies", "audio", "elapsed",
        "input.cursorWorldPosition", "shared.", "shared["
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

/// Runtime evaluator for dynamic WPE transform scripts. This is intentionally
/// narrower than full SceneScript: it supports transform `update(value)` with
/// `engine.canvasSize`/`screenResolution`, `engine.runtime`/`frametime`,
/// `scriptProperties`, `shared`, and `input.cursorWorldPosition`.
final class WPEDynamicTransformScriptInstance: @unchecked Sendable {
    private let engine: Engine
    private let tickBudget: TimeInterval
    private var lastValue: SIMD3<Double>
    private var isPoisoned = false

    init(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        seed: SIMD3<Double>,
        canvasSize: SIMD2<Double>,
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5
    ) throws {
        self.tickBudget = tickBudget
        self.lastValue = seed
        self.engine = Engine(seed: seed, canvasSize: canvasSize, shared: shared)
        var prepared = WPESceneScriptInstance.preprocess(script: script)
        prepared = prepared.replacingOccurrences(
            of: #"(?m)^[\t ]*import\b[^\n]*$"#,
            with: "",
            options: .regularExpression
        )
        if !scriptProperties.isEmpty {
            prepared = wpeNormalizeScriptPropertiesDeclaration(prepared)
        }
        guard let outcome = engine.setUp(
            script: prepared,
            scriptProperties: scriptProperties,
            budget: setupBudget
        ) else {
            isPoisoned = true
            throw WPESceneScriptError.executionTimedOut
        }
        switch outcome {
        case .contextUnavailable:
            throw WPESceneScriptError.contextUnavailable
        case .ready:
            break
        }
    }

    func tick(
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> SIMD3<Double>? {
        guard !isPoisoned else { return nil }
        guard let result = engine.tick(
            currentValue: lastValue,
            pointerPosition: pointerPosition,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) else {
            isPoisoned = true
            return nil
        }
        if let result {
            lastValue = result
        }
        return result
    }

    private final class Engine: @unchecked Sendable {
        enum SetupOutcome {
            case ready
            case contextUnavailable
        }

        private let queue = DispatchQueue(label: "com.livewallpaper.wpe-dynamic-transform", qos: .userInitiated)
        private let seed: SIMD3<Double>
        private let canvasSize: SIMD2<Double>
        private let shared: WPESharedScriptState?
        private var context: JSContext?
        private var updateFunction: JSValue?
        private var cursorWorldPosition: JSValue?
        private var lastRuntimeSeconds: Double?
        private var didThrow = false

        init(seed: SIMD3<Double>, canvasSize: SIMD2<Double>, shared: WPESharedScriptState?) {
            self.seed = seed
            self.canvasSize = canvasSize
            self.shared = shared
        }

        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            budget: TimeInterval
        ) -> SetupOutcome? {
            runWithBudget(budget) { self.setUpOnQueue(script: script, scriptProperties: scriptProperties) }
        }

        func tick(
            currentValue: SIMD3<Double>,
            pointerPosition: SIMD2<Double>,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> SIMD3<Double>?? {
            runWithBudget(budget) {
                self.tickOnQueue(
                    currentValue: currentValue,
                    pointerPosition: pointerPosition,
                    runtimeSeconds: runtimeSeconds
                )
            }
        }

        private func runWithBudget<T>(_ budget: TimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
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
            guard let context = JSContext() else { return .contextUnavailable }
            self.context = context
            WPESceneScriptInstance.installSandbox(in: context)
            WPESceneScriptBaseclasses.install(in: context)
            installCanvasSize(in: context)
            installInput(in: context)
            updateEngineRuntime(0)
            if let shared { wpeInstallSharedState(shared, in: context) }
            context.exceptionHandler = { [weak self] _, _ in self?.didThrow = true }

            didThrow = false
            _ = context.evaluateScript(script)
            guard !didThrow else { return .ready }

            if !scriptProperties.isEmpty {
                wpeInstallScriptProperties(
                    overrides: scriptProperties,
                    declaredDefaults: wpeDeclaredScriptPropertyDefaults(
                        context.objectForKeyedSubscript("scriptProperties")
                    ),
                    into: context
                )
            }
            let update = context.objectForKeyedSubscript("update")
            if let update, !update.isUndefined, update.hasProperty("call") {
                updateFunction = update
            }
            return .ready
        }

        private func tickOnQueue(
            currentValue: SIMD3<Double>,
            pointerPosition: SIMD2<Double>,
            runtimeSeconds: Double?
        ) -> SIMD3<Double>? {
            guard let context, let updateFunction, let valueObject = JSValue(newObjectIn: context) else {
                return nil
            }
            updateEngineRuntime(runtimeSeconds)
            // Renderer pointer UV is top-left; WPE cursorWorldPosition is Y-up canvas space.
            cursorWorldPosition?.setObject(pointerPosition.x * canvasSize.x, forKeyedSubscript: "x" as NSString)
            cursorWorldPosition?.setObject((1.0 - pointerPosition.y) * canvasSize.y, forKeyedSubscript: "y" as NSString)
            cursorWorldPosition?.setObject(seed.z, forKeyedSubscript: "z" as NSString)

            valueObject.setObject(currentValue.x, forKeyedSubscript: "x" as NSString)
            valueObject.setObject(currentValue.y, forKeyedSubscript: "y" as NSString)
            valueObject.setObject(currentValue.z, forKeyedSubscript: "z" as NSString)

            didThrow = false
            guard let result = updateFunction.call(withArguments: [valueObject]),
                  !didThrow,
                  !result.isUndefined, !result.isNull else {
                return nil
            }
            if result.isNumber {
                let scalar = result.toDouble()
                return scalar.isFinite ? SIMD3<Double>(scalar, scalar, scalar) : nil
            }
            guard result.isObject,
                  let xValue = result.objectForKeyedSubscript("x"),
                  let yValue = result.objectForKeyedSubscript("y") else {
                return nil
            }
            let x = xValue.toDouble()
            let y = yValue.toDouble()
            guard x.isFinite, y.isFinite else { return nil }
            let z = result.objectForKeyedSubscript("z")?.toDouble() ?? currentValue.z
            return SIMD3<Double>(x, y, z.isFinite ? z : currentValue.z)
        }

        private func updateEngineRuntime(_ runtimeSeconds: Double?) {
            guard let context,
                  let engine = context.objectForKeyedSubscript("engine"),
                  !engine.isUndefined else { return }
            let runtime: Double
            if let runtimeSeconds, runtimeSeconds.isFinite {
                runtime = runtimeSeconds
            } else {
                runtime = (lastRuntimeSeconds ?? 0) + 1.0 / 30.0
            }
            let frameTime: Double
            if let previous = lastRuntimeSeconds {
                frameTime = max(runtime - previous, 0)
            } else {
                frameTime = 1.0 / 30.0
            }
            lastRuntimeSeconds = runtime
            engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
            engine.setObject(frameTime, forKeyedSubscript: "frametime" as NSString)
        }

        private func installCanvasSize(in context: JSContext) {
            guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
                  let size = JSValue(newObjectIn: context) else { return }
            size.setObject(canvasSize.x, forKeyedSubscript: "x" as NSString)
            size.setObject(canvasSize.y, forKeyedSubscript: "y" as NSString)
            engine.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
            engine.setObject(size, forKeyedSubscript: "screenResolution" as NSString)
        }

        private func installInput(in context: JSContext) {
            let input = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let cursor = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            cursor.setObject(seed.x, forKeyedSubscript: "x" as NSString)
            cursor.setObject(seed.y, forKeyedSubscript: "y" as NSString)
            cursor.setObject(seed.z, forKeyedSubscript: "z" as NSString)
            input.setObject(cursor, forKeyedSubscript: "cursorWorldPosition" as NSString)
            context.setObject(input, forKeyedSubscript: "input" as NSString)
            cursorWorldPosition = cursor
        }

        private final class ResultBox<T>: @unchecked Sendable {
            var value: T?
        }
    }
}
#endif
