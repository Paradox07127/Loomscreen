import Foundation
import LiveWallpaperProWPE
@testable import LiveWallpaper
import Testing

@Suite(.serialized)
@MainActor
struct WPESceneScriptRuntimeTests {
    /// Runtime semantics tests must not contend through the app-global governor
    /// when Swift Testing executes unrelated suites in parallel. Test-local
    /// factories preserve every call site's production-like defaults otherwise.
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func WPESceneScriptInstance(
        script: String,
        initialValue: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) throws -> LiveWallpaper.WPESceneScriptInstance {
        try LiveWallpaper.WPESceneScriptInstance(
            script: script,
            initialValue: initialValue,
            scriptProperties: scriptProperties,
            shared: shared,
            setupBudget: setupBudget,
            tickBudget: tickBudget,
            governor: governor ?? isolatedGovernor
        )
    }

    private func WPELayerScriptInstance(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        canvasSize: SIMD2<Double> = SIMD2<Double>(1920, 1080),
        setupBudget: TimeInterval = 2,
        tickBudget: TimeInterval = 0.5,
        nowProviderMillis: (@Sendable () -> Double)? = nil,
        outputMode: WPELayerScriptOutputMode = .layerState,
        initialVisible: Bool = true,
        initialAlpha: Double = 1,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) throws -> LiveWallpaper.WPELayerScriptInstance {
        try LiveWallpaper.WPELayerScriptInstance(
            script: script,
            scriptProperties: scriptProperties,
            shared: shared,
            canvasSize: canvasSize,
            setupBudget: setupBudget,
            tickBudget: tickBudget,
            nowProviderMillis: nowProviderMillis,
            outputMode: outputMode,
            initialVisible: initialVisible,
            initialAlpha: initialAlpha,
            governor: governor ?? isolatedGovernor
        )
    }

    private func WPETransformScriptEvaluator(
        canvasWidth: Double,
        canvasHeight: Double,
        evaluationBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) -> LiveWallpaper.WPETransformScriptEvaluator {
        LiveWallpaper.WPETransformScriptEvaluator(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            evaluationBudget: evaluationBudget,
            governor: governor ?? isolatedGovernor
        )
    }

    private func WPEDynamicTransformScriptInstance(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        seed: SIMD3<Double>,
        canvasSize: SIMD2<Double>,
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor? = nil
    ) throws -> LiveWallpaper.WPEDynamicTransformScriptInstance {
        try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: script,
            scriptProperties: scriptProperties,
            seed: seed,
            canvasSize: canvasSize,
            shared: shared,
            setupBudget: setupBudget,
            tickBudget: tickBudget,
            governor: governor ?? isolatedGovernor
        )
    }

    @Test("Captures embedded text script during parse")
    func captureTextScriptDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 1,
                "name": "Clock",
                "type": "text",
                "text": {
                    "script": "export function update(value) { return '12:34'; }",
                    "value": "00:00"
                },
                "origin": "0 0 0"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let text = try #require(document.textObjects.first)
        #expect(text.text == "00:00")
        #expect(text.textScript?.contains("update(value)") == true)
    }

    @Test("Script runtime evaluates update() and returns new value")
    func scriptUpdateReturnsNewValue() throws {
        let script = """
        export function update(value) {
            return 'live: ' + value;
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "hello")
        let updated = instance.tickString()
        #expect(updated == "live: hello")
        let next = instance.tickString()
        #expect(next == "live: live: hello")
    }

    @Test("init() runs once at load")
    func initRunsOnceAtLoad() throws {
        let script = """
        var counter = 0;
        export function init() { counter = 100; }
        export function update(value) { counter += 1; return String(counter); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "0")
        let first = instance.tickString()
        #expect(first == "101")
        let second = instance.tickString()
        #expect(second == "102")
    }

    @Test("Script with no update() falls back to initial value")
    func scriptWithoutUpdateFallsBack() throws {
        let script = "var x = 1;"
        let instance = try WPESceneScriptInstance(script: script, initialValue: "static")
        #expect(instance.tickString() == "static")
        #expect(instance.tickString() == "static")
    }

    @Test("createScriptProperties exposes each property's default value")
    func createScriptPropertiesChain() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({name: 'use12hFormat', label: '12h', value: false})
            .addText({name: 'sep', label: 'Sep', value: ':'})
            .finish();
        export function update(value) {
            return scriptProperties.sep + 'OK';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == ":OK")
    }

    @Test("addCombo defaults to its first option's value (date script combos)")
    func comboDefaultsToFirstOption() throws {
        // Reproduces the VHS date bug: the date script declares monthFormat/
        // dayFormat via `addCombo` with NO top-level `value`. WPE defaults a combo
        // to its first option's value, so `scriptProperties.monthFormat == 1` must
        // be true; otherwise `months` stays undefined and `months[...]` throws,
        // leaving the date stuck on its placeholder.
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCombo({ name: 'monthFormat', label: 'Month Format', options: [
                { label: 'Numeric', value: '1' },
                { label: 'Abbreviated', value: '2' }
            ]})
            .finish();
        export function update(value) {
            var months = ['1','2','3','4','5','6','7','8','9','10','11','12'];
            if (scriptProperties.monthFormat == 1) { return 'JAN=' + months[0]; }
            return 'COMBO_UNDEFINED';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "JAN=1")
    }

    @Test("Clock-style script reads property defaults, not 'undefined'")
    func clockScriptPropertyDefaults() throws {
        // Reproduces the VHS clock bug: a missing `delimiter`/`use24hFormat`
        // default stringified to "undefined" between the hours and minutes.
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({name: 'use24hFormat', value: true})
            .addText({name: 'delimiter', value: ':'})
            .finish();
        export function update(value) {
            return '03' + scriptProperties.delimiter + '30' + '/' + scriptProperties.use24hFormat;
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "03:30/true")
    }

    @Test("engine.getTimeOfDay returns 0..1")
    func engineGetTimeOfDay() throws {
        let script = """
        export function update(value) {
            var t = engine.getTimeOfDay();
            if (t < 0 || t > 1) return 'OUT_OF_RANGE';
            return 'ok';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(instance.tickString() == "ok")
    }

    @Test("engine.registerAudioBuffers returns a zeroed average buffer")
    func engineRegisterAudioBuffersReturnsZeroedAverageBuffer() throws {
        let script = """
        let audioBuffer = engine.registerAudioBuffers(4);
        export function update(value) {
            return String(audioBuffer.average.length) + ':' + String(audioBuffer.average[2]);
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "")
        #expect(instance.tickString() == "4:0")
    }

    @Test("localstorage.set/get round-trip")
    func localstorageRoundTrip() throws {
        let script = """
        export function init() { localstorage.set('key', 'value-set'); }
        export function update(value) {
            return localstorage.get('key') || 'missing';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(instance.tickString() == "value-set")
    }

    // MARK: - WPE 2.8 baseclasses (Vec/Mat math + tolerant globals)

    @Test("Vec3 math from the 2.8 baseclasses computes correctly")
    func vec3MathAvailable() throws {
        // A wrong/absent Vec3 would throw → the runtime falls back to the
        // initial value, so a correct numeric result proves the class ran.
        let script = """
        export function update(value) { return String(new Vec3(0, 3, 4).length()); }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "5")
    }

    @Test("Mat4.identity().normalMatrix() is the identity 3×3")
    func mat4NormalMatrixIdentity() throws {
        // Guards the column-major Mat4 identity: a corrupt identity would make
        // inverse/normalMatrix diverge from the identity 3×3.
        let script = """
        export function update(value) {
            return Mat4.identity().normalMatrix().m.join(',');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "1,0,0,0,1,0,0,0,1")
    }

    @Test("Mat3.inverse() is the true inverse, not its transpose")
    func mat3InverseIsTrueInverse() throws {
        // Regression: inverse() used to return the cofactor matrix (the
        // transpose of the inverse) for non-symmetric M. M·M⁻¹ must be the
        // identity 3×3; a transposed inverse fails this. M below has det = 1.
        let script = """
        export function update(value) {
            var m = new Mat3([1, 2, 3, 0, 1, 4, 5, 6, 0]);
            var p = m.multiply(m.inverse()).m;
            var ok = true;
            var id = [1, 0, 0, 0, 1, 0, 0, 0, 1];
            for (var i = 0; i < 9; i += 1) {
                if (Math.abs(p[i] - id[i]) > 1e-9) { ok = false; }
            }
            return ok ? 'identity' : p.join(',');
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "identity")
    }

    @Test("Tolerant globals make scene/thisLayer/timers/model references harmless")
    func tolerantGlobalsNeverThrow() throws {
        // These are the exact 2.8 failure shapes from the WPE install log:
        // `scene is not defined`, `setTimeout is not defined`, and null derefs
        // on `.origin` / `.visible`. With the baseclasses they must not throw —
        // a clean "tolerant" result proves no ReferenceError/TypeError fired.
        let script = """
        export function update(value) {
            setTimeout(function () {}, 16);
            var origin = thisLayer.origin;
            origin.x;
            thisLayer.visible = false;
            scene.customField = 42;
            var model = getModel('character');
            var depth = model.bones.head.position.z;
            return 'tolerant';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "tolerant")
    }

    @Test("Baseclasses do not clobber the existing engine sandbox")
    func baseclassesPreserveExistingSandbox() throws {
        let script = """
        export function update(value) {
            return (typeof engine.getTimeOfDay === 'function') ? 'kept' : 'lost';
        }
        """
        let instance = try WPESceneScriptInstance(script: script, initialValue: "init")
        #expect(instance.tickString() == "kept")
    }

    @Test("Text SceneScript reads the scene shared state")
    func textSceneScriptReadsSharedState() throws {
        let store = WPESharedScriptState()
        store.set("ip1", "Local/1st Arm/")
        store.set("num", 42.0)
        let instance = try WPESceneScriptInstance(
            script: """
            export function update(value) {
                return shared.ip1 + shared.num;
            }
            """,
            initialValue: "",
            shared: store
        )

        #expect(instance.tickString() == "Local/1st Arm/42")
    }

    @Test("Current synchronous containment is deadline plus poison, not termination")
    func synchronousTimeoutSourceContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // M2c1b-3c: the instance is no longer @MainActor (it ticks on the render
        // actor); the class declaration alone is the boundary.
        let start = try #require(source.range(of: "final class WPESceneScriptInstance"))
        let end = try #require(source.range(of: "enum WPESceneScriptError", range: start.upperBound ..< source.endIndex))
        let instanceSource = String(source[start.lowerBound ..< end.lowerBound])

        // Current production waits only at the caller boundary. A deadline
        // poisons/quarantines the instance, setup throws, and ticks keep the last
        // value; no public JavaScriptCore termination seam is invoked.
        #expect(instanceSource.contains("done.wait(timeout: deadline)"))
        #expect(instanceSource.contains("safety.quarantine(self, operation: operation)"))
        #expect(!instanceSource.contains("static var quarantine"))
        #expect(!instanceSource.contains("quarantine.append"))
        #expect(instanceSource.contains("throw WPESceneScriptError.executionTimedOut"))
        #expect(instanceSource.contains("return lastValue"))
        for absentTerminationSeam in [
            "terminateExecution",
            "TerminateExecution",
            "executionTimeLimit",
            "JSContextGroupSetExecutionTimeLimit",
        ] {
            #expect(!instanceSource.contains(absentTerminationSeam))
        }
    }

    @Test("Setup capacity rejection is structured and dispatches no evaluator")
    func setupCapacityRejectionIsStructured() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        defer { heldPermit.release() }
        let expected = WPESceneScriptError.capacityUnavailable(operation: .setup)

        #expect(throws: expected) {
            _ = try WPESceneScriptInstance(
                script: "export function update(value) { return value; }",
                initialValue: "seed",
                setupBudget: 0.001,
                governor: governor
            )
        }
        #expect(throws: expected) {
            _ = try WPELayerScriptInstance(
                script: "export function update() { thisLayer.visible = false; }",
                setupBudget: 0.001,
                governor: governor
            )
        }
        #expect(throws: expected) {
            _ = try WPEDynamicTransformScriptInstance(
                script: "export function update(value) { return value; }",
                seed: .zero,
                canvasSize: SIMD2<Double>(100, 100),
                setupBudget: 0.001,
                governor: governor
            )
        }
        let staticEvaluator = WPETransformScriptEvaluator(
            canvasWidth: 100,
            canvasHeight: 100,
            evaluationBudget: 0.001,
            governor: governor
        )
        #expect(staticEvaluator.resolveVec3(
            script: "export function update(value) { value.x = 7; value.y = 8; return value; }",
            properties: [:],
            seed: .zero
        ) == nil)
    }

    @Test("Capacity saturation keeps stable values and evaluators recover")
    func capacitySaturationKeepsStableValues() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let text = try WPESceneScriptInstance(
            script: "export function update(value) { return 'updated-' + value; }",
            initialValue: "seed",
            governor: governor
        )
        let layer = try WPELayerScriptInstance(
            script: "export function update() { thisLayer.visible = false; }",
            governor: governor
        )
        let transform = try WPEDynamicTransformScriptInstance(
            script: "export function update(value) { value.x += 1; return value; }",
            seed: .zero,
            canvasSize: SIMD2<Double>(100, 100),
            governor: governor
        )
        let staticEvaluator = WPETransformScriptEvaluator(
            canvasWidth: 100,
            canvasHeight: 100,
            governor: governor
        )

        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        #expect(text.tickString() == "seed")
        #expect(text.liveTickString() == "seed")
        #expect(text.liveTickString() == "seed", "capacity rejection must return the async claim")
        #expect(layer.tick() == nil)
        #expect(transform.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)) == .zero)
        #expect(staticEvaluator.resolveVec3(
            script: "export function update(value) { value.x = 7; value.y = 8; return value; }",
            properties: [:],
            seed: .zero
        ) == nil)
        heldPermit.release()

        #expect(text.tickString() == "updated-seed")
        #expect(layer.tick()?.own.visible == false)
        #expect(transform.tick(pointerPosition: SIMD2<Double>(0.5, 0.5))?.x == 1)
        #expect(staticEvaluator.resolveVec3(
            script: "export function update(value) { value.x = 7; value.y = 8; return value; }",
            properties: [:],
            seed: .zero
        ) == SIMD3<Double>(7, 8, 0))
    }

    @Test("Fair frame admission lets two production evaluators progress at limit one")
    func fairAdmissionLetsProductionEvaluatorsProgress() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let first = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-first'; }",
            initialValue: "seed",
            governor: governor
        )
        let second = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-second'; }",
            initialValue: "seed",
            governor: governor
        )
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        let saturatedEpoch = WPESceneScriptTraversalEpoch.next(domainID: 1_001)

        // Reverse the reservation order, then probe in fixed first/second order.
        // FIFO must make the first probe yield instead of stealing every round.
        #expect(second.tickString(traversalEpoch: saturatedEpoch) == "seed")
        #expect(first.tickString(traversalEpoch: saturatedEpoch) == "seed")
        heldPermit.release()

        let recoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 1_001)
        #expect(first.tickString(traversalEpoch: recoveryEpoch) == "seed")
        #expect(second.tickString(traversalEpoch: recoveryEpoch) == "seed-second")
        #expect(first.tickString(traversalEpoch: recoveryEpoch) == "seed-first")
        #expect(second.tickString(traversalEpoch: recoveryEpoch) == "seed-second-second")
        #expect(first.tickString(traversalEpoch: recoveryEpoch) == "seed-first-first")
    }

    @Test("Fair frame admission does not starve a tail behind five production evaluators")
    func fairAdmissionLetsSixProductionEvaluatorsProgress() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let prefix = try (0 ..< 5).map { index in
            try WPESceneScriptInstance(
                script: "export function update(value) { return value + '-p\(index)'; }",
                initialValue: "seed-p\(index)",
                governor: governor
            )
        }
        let tail = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-tail'; }",
            initialValue: "seed-tail",
            governor: governor
        )
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        let firstSaturatedEpoch = WPESceneScriptTraversalEpoch.next(domainID: 1_002)

        // Reserve the tail first, then five earlier-in-render-order evaluators.
        // One explicit traversal token makes every repeated probe inert, so the
        // prefix cannot evict the tail before its turn when capacity returns.
        #expect(tail.tickString(traversalEpoch: firstSaturatedEpoch) == "seed-tail")
        for (index, instance) in prefix.enumerated() {
            #expect(instance.tickString(traversalEpoch: firstSaturatedEpoch) == "seed-p\(index)")
        }
        heldPermit.release()

        // Production evaluator calls, not a test-side governor model. The first
        // fixed-order traversal must yield to the reserved tail; the following
        // traversal lets every prefix advance as well.
        let firstRecoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 1_002)
        for instance in prefix {
            _ = instance.tickString(traversalEpoch: firstRecoveryEpoch)
        }
        #expect(tail.tickString(traversalEpoch: firstRecoveryEpoch) == "seed-tail-tail")

        let firstPrefixProgress = prefix.map {
            $0.tickString(traversalEpoch: firstRecoveryEpoch)
        }
        for (index, value) in firstPrefixProgress.enumerated() {
            #expect(value == "seed-p\(index)-p\(index)")
        }

        // Repeat the same saturated ordering to prove progress across rounds,
        // rather than relying on an uncontended follow-up call.
        let secondHeldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        let secondSaturatedEpoch = WPESceneScriptTraversalEpoch.next(domainID: 1_002)
        #expect(tail.tickString(traversalEpoch: secondSaturatedEpoch) == "seed-tail-tail")
        for (index, instance) in prefix.enumerated() {
            #expect(
                instance.tickString(traversalEpoch: secondSaturatedEpoch)
                    == "seed-p\(index)-p\(index)"
            )
        }
        secondHeldPermit.release()

        let secondRecoveryEpoch = WPESceneScriptTraversalEpoch.next(domainID: 1_002)
        for (index, instance) in prefix.enumerated() {
            #expect(
                instance.tickString(traversalEpoch: secondRecoveryEpoch)
                    == "seed-p\(index)-p\(index)"
            )
        }
        #expect(tail.tickString(traversalEpoch: secondRecoveryEpoch) == "seed-tail-tail-tail")
        for (index, instance) in prefix.enumerated() {
            #expect(
                instance.tickString(traversalEpoch: secondRecoveryEpoch)
                    == "seed-p\(index)-p\(index)-p\(index)"
            )
        }
    }

    @Test("Setup waits fairly through temporary saturation within its deadline")
    func setupWaitsThroughTemporarySaturation() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        let releaser = DispatchQueue(label: "com.livewallpaper.tests.scenescript-setup-release")
        releaser.asyncAfter(deadline: .now() + 0.01) {
            heldPermit.release()
        }

        let instance = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-ready'; }",
            initialValue: "seed",
            setupBudget: 1,
            governor: governor
        )
        #expect(instance.tickString() == "seed-ready")
    }

    @Test("Dynamic sync capacity saturation keeps the last stable transform")
    func dynamicSyncCapacityKeepsLastValue() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let instance = try WPEDynamicTransformScriptInstance(
            script: "export function update(value) { value.x += 1; return value; }",
            seed: SIMD3<Double>(3, 4, 5),
            canvasSize: SIMD2<Double>(100, 100),
            governor: governor
        )
        let blocker = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: blocker))
        defer { heldPermit.release() }

        #expect(instance.tick(pointerPosition: .zero) == SIMD3<Double>(3, 4, 5))
    }

    // MARK: - WPETransformScriptEvaluator (static origin scripts)

    /// The exact WPE origin script the corpus uses: fraction × canvasSize.
    private static let originScript = """
    'use strict';
    export var scriptProperties = createScriptProperties()
        .addSlider({name: 'x', value: 0.5, min: 0, max: 1})
        .addSlider({name: 'y', value: 0.5, min: 0, max: 1})
        .finish();
    export function update(value) {
        value.x = scriptProperties.x * engine.canvasSize.x;
        value.y = scriptProperties.y * engine.canvasSize.y;
        return value;
    }
    """

    @Test("Origin script resolves bound scriptProperties × canvasSize")
    func originScriptResolvesToFractionTimesCanvas() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 3840, canvasHeight: 2160)
        let origin = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.112), "y": .number(0.434)],
            seed: SIMD3<Double>(99, 99, 7)
        ))
        #expect(abs(origin.x - 0.112 * 3840) < 0.001)
        #expect(abs(origin.y - 0.434 * 2160) < 0.001)
        // The script never touches z → the seed's z passes through untouched.
        #expect(origin.z == 7)
    }

    @Test("Bound scriptProperties override the script's declared defaults")
    func boundPropertiesOverrideDeclaredDefaults() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1000, canvasHeight: 1000)
        // Declared defaults are 0.5; the bound values must win.
        let origin = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(-0.29), "y": .number(0.0)],
            seed: SIMD3<Double>(0, 0, 0)
        ))
        #expect(abs(origin.x - (-290)) < 0.001)
        #expect(origin.y == 0)
    }

    @Test("One evaluator reuses a context per source across many objects")
    func evaluatorReusesContextPerSource() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 800, canvasHeight: 600)
        let a = try #require(evaluator.resolveVec3(
            script: Self.originScript, properties: ["x": .number(0.25), "y": .number(0.5)], seed: .init(0, 0, 0)))
        let b = try #require(evaluator.resolveVec3(
            script: Self.originScript, properties: ["x": .number(0.75), "y": .number(0.25)], seed: .init(0, 0, 0)))
        #expect(abs(a.x - 200) < 0.001 && abs(a.y - 300) < 0.001)
        #expect(abs(b.x - 600) < 0.001 && abs(b.y - 150) < 0.001)
    }

    @Test("Shared context does not leak one object's bindings into the next")
    func sharedContextDoesNotLeakBindings() throws {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1000, canvasHeight: 1000)
        // First object binds x=0.25; second omits x entirely (same source) and must
        // fall back to the script's DECLARED default 0.5, not inherit 0.25.
        let first = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.25), "y": .number(0.25)],
            seed: .init(0, 0, 0)))
        let second = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: [:],
            seed: .init(0, 0, 0)))
        #expect(abs(first.x - 250) < 0.001)
        #expect(abs(second.x - 500) < 0.001)   // declared default 0.5 × 1000, NOT 250
        #expect(abs(second.y - 500) < 0.001)
    }

    @Test("Overrides apply even when scriptProperties is declared const/let")
    func overridesApplyToConstScriptProperties() throws {
        // `export const` becomes a lexical binding JSC keeps off the global object;
        // without normalization the override would be silently ignored.
        let constScript = """
        'use strict';
        export const scriptProperties = createScriptProperties()
            .addSlider({name: 'x', value: 0.5})
            .addSlider({name: 'y', value: 0.5})
            .finish();
        export function update(value) {
            value.x = scriptProperties.x * engine.canvasSize.x;
            value.y = scriptProperties.y * engine.canvasSize.y;
            return value;
        }
        """
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1000, canvasHeight: 1000)
        let origin = try #require(evaluator.resolveVec3(
            script: constScript,
            properties: ["x": .number(0.3), "y": .number(0.7)],
            seed: .init(0, 0, 0)
        ))
        #expect(abs(origin.x - 300) < 0.001) // override wins over the const default 0.5
        #expect(abs(origin.y - 700) < 0.001)
    }

    @Test("Dynamic (audio/time/random) scripts are not statically resolved")
    func dynamicScriptsAreSkipped() {
        #expect(LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(Self.originScript))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = engine.getFrequency(0); return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = engine.runtime; return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = Math.random(); return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = input.cursorWorldPosition.x; return v; }"
        ))
        #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = shared.xx1; return v; }"
        ))
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 100, canvasHeight: 100)
        #expect(evaluator.resolveVec3(
            script: "export function update(v){ v.x = engine.getTimeOfDay(); return v; }",
            properties: [:], seed: .init(1, 2, 3)
        ) == nil)
    }

    @Test("Dynamic origin script follows cursorWorldPosition in WPE y-up canvas pixels")
    func dynamicOriginScriptFollowsCursorWorldPosition() throws {
        let script = """
        'use strict';
        export function update(value) {
            value.x = input.cursorWorldPosition.x;
            value.y = input.cursorWorldPosition.y;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(860.29364, 133.27734, 9),
            canvasSize: SIMD2<Double>(3840, 2160)
        )

        let origin = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.25, 0.75)))

        #expect(origin == SIMD3<Double>(960, 540, 9))
    }

    @Test("Dynamic origin script reads the scene shared state")
    func dynamicOriginScriptReadsSceneSharedState() throws {
        let store = WPESharedScriptState()
        store.set("xx1", 12.5)
        store.set("yy1", -3.25)
        store.set("zz1", 4.75)
        let script = """
        'use strict';
        export function update(value) {
            value.x = shared.xx1;
            value.y = shared.yy1;
            value.z = shared.zz1;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 1, 0),
            canvasSize: SIMD2<Double>(3840, 2160),
            shared: store
        )

        let origin = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))

        #expect(origin == SIMD3<Double>(12.5, -3.25, 4.75))
    }

    @Test("Dynamic origin script accepts WPE non-breaking keyword spaces")
    func dynamicOriginScriptAcceptsWPENonBreakingKeywordSpaces() throws {
        let nbsp = "\u{00A0}"
        let script = """
        'use\(nbsp)strict';
        export\(nbsp)function\(nbsp)update(value) {
            value.x = input.cursorWorldPosition.x;
            value.y = input.cursorWorldPosition.y;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(860.29364, 133.27734, 9),
            canvasSize: SIMD2<Double>(3840, 2160)
        )

        let origin = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.25, 0.75)))

        #expect(origin == SIMD3<Double>(960, 540, 9))
    }

    @Test("Static origin evaluator rejects loop constructs before JS evaluation")
    func staticOriginScriptsRejectLoopConstructs() throws {
        let loopScripts = [
            "export function update(v){ while (true) {} return v; }",
            "export function update(v){ for (;;) {} return v; }",
            "export function update(v){ do {} while (true); return v; }",
        ]

        for script in loopScripts {
            #expect(!LiveWallpaper.WPETransformScriptEvaluator.isStaticallyResolvable(script))
        }

        let evaluator = WPETransformScriptEvaluator(
            canvasWidth: 100,
            canvasHeight: 100,
            evaluationBudget: 0.1
        )
        #expect(evaluator.resolveVec3(script: loopScripts[0], properties: [:], seed: .init(5, 6, 7)) == nil)

        let origin = try #require(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.5), "y": .number(0.5)],
            seed: .init(1, 2, 3)
        ))
        #expect(origin == SIMD3<Double>(50, 50, 3))
    }

    @Test("Origin script can branch on a bool scriptProperty")
    func originScriptBranchesOnBoolProperty() throws {
        // The script declares `flip` (default false); the bound .bool(true) must
        // override it, exercising the non-numeric scriptProperty path.
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({name: 'flip', value: false})
            .finish();
        export function update(value) {
            value.x = scriptProperties.flip ? 10 : 20;
            return value;
        }
        """
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1, canvasHeight: 1)
        let flipped = try #require(evaluator.resolveVec3(
            script: script, properties: ["flip": .bool(true)], seed: .init(0, 0, 0)))
        #expect(flipped.x == 10)
        let plain = try #require(evaluator.resolveVec3(
            script: script, properties: ["flip": .bool(false)], seed: .init(0, 0, 0)))
        #expect(plain.x == 20)
    }

    @Test("Parser applies script origin under a parent's transform")
    func parserAppliesScriptOriginBeneathParent() throws {
        // Parent at (2408, 971) mirrored on X (scale -1); child origin is scripted.
        // Expected world X = parent.x + (-1) * childLocal.x; world Y = parent.y + childLocal.y.
        let escaped = Self.originScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 1000, "height": 1000, "auto": true}},
            "objects": [
                {"id": 10, "name": "group", "scale": "-1 1 1", "origin": "2408 971 0"},
                {"id": 11, "name": "Clock", "type": "text", "parent": 10,
                 "text": "12:34",
                 "origin": {"script": "\(escaped)",
                            "scriptproperties": {"x": 0.25, "y": 0.10},
                            "value": "999 999 0"}}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let clock = try #require(document.textObjects.first { $0.id == "11" })
        // childLocal = (0.25*1000, 0.10*1000) = (250, 100); parent mirror flips X.
        #expect(abs(clock.origin.x - (2408 - 250)) < 0.01)
        #expect(abs(clock.origin.y - (971 + 100)) < 0.01)
    }

    @Test("Stale baked origin is replaced, not used, when a script is present")
    func staleBakedOriginIsReplaced() throws {
        let escaped = Self.originScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 2000, "height": 2000, "auto": true}},
            "objects": [
                {"id": 12, "name": "T", "type": "text", "text": "x",
                 "origin": {"script": "\(escaped)",
                            "scriptproperties": {"x": 0.5, "y": 0.5},
                            "value": "12345 67890 0"}}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let text = try #require(document.textObjects.first)
        #expect(abs(text.origin.x - 1000) < 0.01)   // 0.5 * 2000, NOT the baked 12345
        #expect(abs(text.origin.y - 1000) < 0.01)
    }

    @Test("Image localOrigin uses the script-resolved local origin, not stale baked")
    func imageLocalOriginUsesScriptOrigin() throws {
        let escaped = Self.originScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 1000, "height": 1000, "auto": true}},
            "objects": [
                {"id": 50, "name": "group", "origin": "100 200 0"},
                {"id": 51, "name": "img", "image": "materials/x.png", "parent": 50,
                 "origin": {"script": "\(escaped)",
                            "scriptproperties": {"x": 0.25, "y": 0.40},
                            "value": "999 999 7"}}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let image = try #require(document.imageObjects.first { $0.id == "51" })
        // localOrigin = script local (0.25*1000, 0.40*1000, baked z) — NOT baked 999.
        #expect(abs(image.localOrigin.x - 250) < 0.01)
        #expect(abs(image.localOrigin.y - 400) < 0.01)
        // world origin combines the parent offset onto the fresh local origin.
        #expect(abs(image.origin.x - 350) < 0.01)
        #expect(abs(image.origin.y - 600) < 0.01)
    }

    // MARK: - Text-content script scriptProperties injection (Mon vs Monday)

    @Test("Text script renders with the scene's scriptProperties, not just defaults")
    func textScriptUsesSceneScriptProperties() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCombo({name: 'dayFormat', options: [
                {label: 'Abbreviated', value: '1'},
                {label: 'Full', value: '2'}
            ]})
            .finish();
        export function update(value) {
            return scriptProperties.dayFormat == '2' ? 'Monday' : 'Mon';
        }
        """
        // No scene override → combo defaults to its first option ('1') → "Mon".
        let bare = try WPESceneScriptInstance(script: script, initialValue: "?")
        #expect(bare.tickString() == "Mon")
        // The scene configures Full ('2') → "Monday", matching Windows WPE.
        let configured = try WPESceneScriptInstance(
            script: script,
            initialValue: "?",
            scriptProperties: ["dayFormat": .string("2")])
        #expect(configured.tickString() == "Monday")
    }

    @Test("Injected scriptProperties survive a const declaration in a text script")
    func textScriptConstScriptPropertiesInjected() throws {
        let script = """
        export const scriptProperties = createScriptProperties()
            .addCheckbox({name: 'showDay', value: true})
            .finish();
        export function update(value) {
            return scriptProperties.showDay ? 'SHOW' : 'HIDE';
        }
        """
        let configured = try WPESceneScriptInstance(
            script: script,
            initialValue: "?",
            scriptProperties: ["showDay": .bool(false)])
        #expect(configured.tickString() == "HIDE")
    }

    // MARK: - Ancestor-aware visibility (weekday 横/竖 both showing)

    @Test("A text child of a condition-hidden parent group is hidden")
    func textChildOfHiddenGroupIsHidden() throws {
        // Mirrors weekday: parent "横Day" hidden by a combo, child's own visible true.
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 100, "height": 100, "auto": true}},
            "objects": [
                {"id": 1, "name": "横Day", "visible": false},
                {"id": 2, "name": "竖Day", "visible": true},
                {"id": 3, "name": "DAY", "type": "text", "text": "DAY", "parent": 1, "visible": true},
                {"id": 4, "name": "SUN", "type": "text", "text": "SUN", "parent": 2, "visible": true}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let horizontal = try #require(document.textObjects.first { $0.id == "3" })
        let vertical = try #require(document.textObjects.first { $0.id == "4" })
        #expect(horizontal.visible == false)   // hidden via parent group 1
        #expect(vertical.visible == true)
    }

    @Test("Ancestor visibility folds through a multi-level group chain")
    func ancestorVisibilityFoldsThroughChain() throws {
        let json = """
        {
            "camera": {"center": "0 0 0"},
            "general": {"orthogonalprojection": {"width": 100, "height": 100, "auto": true}},
            "objects": [
                {"id": 1, "name": "root", "visible": false},
                {"id": 2, "name": "mid", "parent": 1, "visible": true},
                {"id": 3, "name": "leaf", "type": "text", "text": "x", "parent": 2, "visible": true}
            ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let leaf = try #require(document.textObjects.first { $0.id == "3" })
        #expect(leaf.visible == false)   // grandparent hidden → leaf hidden
    }

    // MARK: - Layer visible-script (video intro)

    @Test("Visible-script on an image object is captured during parse")
    func captureVisibleScriptDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7, "name": "Intro", "image": "models/intro.json",
                "visible": { "script": "export function update(){}", "value": true }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let image = try #require(document.imageObjects.first)
        #expect(image.visibleScript?.contains("update") == true)
    }

    @Test("Visible-script with a user binding is still captured (not collapsed to a bool)")
    func captureVisibleScriptWithUserBinding() throws {
        // A `visible: {script, user, value}` envelope (e.g. the 千咲拉镜 intro layer)
        // must keep its script — the user-property pre-pass must not collapse it to
        // the bool `value`, which would drop the script and let the video auto-loop.
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7, "name": "Intro", "image": "models/intro.json",
                "visible": { "script": "export function update(){}", "user": "ruchang", "value": true }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: ["ruchang": .bool(true)])
        let image = try #require(document.imageObjects.first)
        #expect(image.visibleScript?.contains("update") == true)
    }

    @Test("Alpha-script on an image object is captured during parse")
    func captureAlphaScriptDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 449,
                "name": "RST界面背景备用",
                "image": "models/black.json",
                "alpha": {
                    "script": "export function update(value){ return engine.runtime > 2 ? 0 : value; }",
                    "scriptproperties": { "peakvalue": { "user": "newproperty15", "value": 0.25 } },
                    "value": 1
                }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let image = try #require(document.imageObjects.first)
        #expect(image.alpha == 1)
        #expect(image.alphaScript?.contains("engine.runtime") == true)
        #expect(image.alphaScriptProperties["peakvalue"] == .number(0.25))
    }

    @Test("Non-rendered solid visible-script is captured as a script host")
    func captureSolidVisibleScriptHostDuringParse() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 1326,
                "name": "MAIN",
                "solid": true,
                "visible": {
                    "script": "export function update(value){ shared.dd = 1; return value; }",
                    "value": true
                }
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let host = try #require(document.scriptHostObjects.first)
        #expect(host.id == "1326")
        #expect(host.visibleScript.contains("shared.dd"))
        #expect(document.imageObjects.isEmpty)
    }

    @Test("Layer alpha-script returns live alpha from update(value)")
    func layerAlphaScriptUsesRuntimeReturnValue() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'peakvalue', value: 1 })
            .finish();
        export function update(value) {
            if (engine.runtime <= 2) { return value; }
            return 1 - Math.min((engine.runtime - 2) / 3, 1) * scriptProperties.peakvalue;
        }
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            scriptProperties: ["peakvalue": .number(1)],
            outputMode: .returnedAlpha(initialValue: 1)
        )

        #expect(instance.initialOutput.own.alpha == 1)
        let early = try #require(instance.tick(runtimeSeconds: 1)?.own)
        #expect(early.alpha == 1)
        let faded = try #require(instance.tick(runtimeSeconds: 5)?.own)
        #expect(faded.visible == true)
        #expect(faded.alpha == 0)
    }

    @Test("Layer alpha-script can read engine.frametime")
    func layerAlphaScriptReadsFrameTime() throws {
        let script = """
        export function update(value) {
            return value + engine.frametime;
        }
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            outputMode: .returnedAlpha(initialValue: 0)
        )

        let first = try #require(instance.tick(runtimeSeconds: 1)?.own)
        #expect(first.alpha == 1)
        let second = try #require(instance.tick(runtimeSeconds: 1.25)?.own)
        #expect(abs(second.alpha - 1.25) < 0.0001)
    }

    @Test("Dynamic transform script receives previous returned value")
    func dynamicTransformScriptReceivesPreviousReturnedValue() throws {
        let script = """
        export function update(value) {
            value.x = value.x + 1;
            value.y = value.y + 2;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )

        let first = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))
        let second = try #require(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))

        #expect(first == SIMD3<Double>(11, 22, 30))
        #expect(second == SIMD3<Double>(12, 24, 30))
    }

    @Test("Dynamic transform script reads runtime, frametime, and screen resolution")
    func dynamicTransformScriptReadsEngineTimeAndScreenResolution() throws {
        let script = """
        export function update(value) {
            value.x = engine.runtime;
            value.y = value.y + engine.frametime;
            value.z = engine.screenResolution.x;
            return value;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 50)
        )

        let first = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 1
        ))
        let second = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 1.25
        ))

        #expect(first == SIMD3<Double>(1, 1, 100))
        #expect(second == SIMD3<Double>(1.25, 1.25, 100))
    }

    @Test("Dynamic transform script expands a scalar return to a uniform vector")
    func dynamicTransformScriptExpandsScalarReturn() throws {
        let script = """
        export function update(value) {
            return engine.runtime > 1 ? 2 : 3;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(1, 1, 1),
            canvasSize: SIMD2<Double>(100, 50)
        )

        let first = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 0.5
        ))
        let second = try #require(instance.tick(
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            runtimeSeconds: 2
        ))

        #expect(first == SIMD3<Double>(3, 3, 3))
        #expect(second == SIMD3<Double>(2, 2, 2))
    }

    @Test("Layer video-intro script: init hides+stops, plays once, hides after timeout")
    func layerVideoIntroPlaysOnce() throws {
        let script = """
        'use strict';
        import * as WEMath from 'WEMath';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'play', value: true })
            .addCheckbox({ name: 'hideStopped', value: true })
            .finish();
        let video, stopped = false, startTime = 0, fadeStartTime = 0, fadingOut = false;
        export function init() {
            thisLayer.visible = false;
            video = thisLayer.getVideoTexture();
            video.stop();
            video.setCurrentTime(0);
            thisLayer.alpha = 1;
        }
        export function update() {
            const currentTime = Date.now();
            if (!stopped && scriptProperties.play) {
                if (startTime === 0) { startTime = currentTime; video.play(); }
                else if (currentTime - startTime >= 15000) {
                    if (!fadingOut) { fadingOut = true; fadeStartTime = currentTime; }
                    const fadeProgress = (currentTime - fadeStartTime) / 1000;
                    if (fadeProgress < 1) { thisLayer.alpha = 1 - fadeProgress; }
                    else { thisLayer.alpha = 0; video.stop(); stopped = true; if (scriptProperties.hideStopped) thisLayer.visible = false; }
                } else { thisLayer.alpha = 1; }
            }
            thisLayer.visible = thisLayer.alpha > 0.001;
        }
        """

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var ms: Double = 0
            func now() -> Double { lock.lock(); defer { lock.unlock() }; return ms }
            func set(_ value: Double) { lock.lock(); ms = value; lock.unlock() }
        }
        let clock = Clock()
        let instance = try WPELayerScriptInstance(script: script, nowProviderMillis: { clock.now() })

        #expect(instance.initialOutput.own.visible == false)
        #expect(instance.initialOutput.own.alpha == 1)
        #expect(instance.initialOutput.own.videoCommands.contains(.stop))
        #expect(instance.initialOutput.own.videoCommands.contains(.seek(0)))

        // Use a realistic epoch base — the script treats `startTime === 0` as its
        // "not started" sentinel, so a literal 0 would collide with real time.
        let base: Double = 1_000_000
        clock.set(base)
        let first = try #require(instance.tick()).own
        #expect(first.videoCommands.contains(.play))
        #expect(first.alpha == 1)
        #expect(first.visible == true)

        clock.set(base + 5000)
        let mid = try #require(instance.tick()).own
        #expect(mid.visible == true)
        #expect(mid.videoCommands.isEmpty)

        // Fade begins past 15s, completes ~1s later → stopped + hidden.
        clock.set(base + 16100)
        _ = instance.tick()
        clock.set(base + 17300)
        let end = try #require(instance.tick()).own
        #expect(end.videoCommands.contains(.stop))
        #expect(end.visible == false)
        #expect(end.alpha == 0)
    }

    @Test("getLayer drives another layer: button init stops + hides the target video")
    func getLayerControlsAnotherLayer() throws {
        // Mirrors the 入场动画开关 button: its init() hides + stops a SEPARATE
        // video layer via thisScene.getLayer(name).
        let script = """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'enableScript', value: true })
            .finish();
        let target, video;
        export function init() {
            thisLayer.visible = true;
            target = thisScene.getLayer('千咲入场动画');
            video = target.getVideoTexture();
            video.stop();
            video.setCurrentTime(0);
            target.alpha = 0;
            target.visible = false;
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        let other = try #require(instance.initialOutput.others["千咲入场动画"])
        #expect(other.visible == false)
        #expect(other.alpha == 0)
        #expect(other.videoCommands.contains(.stop))
        #expect(other.videoCommands.contains(.seek(0)))
        #expect(instance.initialOutput.own.visible == true)
    }

    @Test("getLayer READ-only reference does not drive the layer (3226487183 variant overlap)")
    func getLayerReadOnlyReferenceDoesNotDrive() throws {
        // 3226487183's 点击切换面具 (1293): its update() READS
        // getLayer('中面具身体背景').visible for a conditional but never assigns it.
        // A read must not clobber the layer's real (condition-form-hidden) state —
        // otherwise the handle's default visible=true force-shows the mutually
        // exclusive mask body over the correct default character.
        let script = """
        'use strict';
        var probedVisible = true;
        export function update() {
            // read-only: reference the layer + read its visibility, never assign
            var probed = thisScene.getLayer('中面具身体背景');
            probedVisible = probed.visible;
            // a SEPARATE layer IS explicitly driven — that one must still appear
            thisScene.getLayer('面具花').visible = true;
        }
        """
        let instance = try WPELayerScriptInstance(script: script)
        let output = try #require(instance.tick())
        // read-only reference is NOT driven
        #expect(output.others["中面具身体背景"] == nil)
        // explicit assignment IS driven
        #expect(output.others["面具花"]?.visible == true)
        #expect(output.others["面具花"]?.visibleAssigned == true)
    }

    @Test("getLayer alpha-only assignment does not force visible")
    func getLayerAlphaOnlyDoesNotForceVisible() throws {
        // Setting only .alpha must leave .visible untouched (visibleAssigned == false),
        // so the renderer patches alpha without clobbering the layer's visibility.
        let script = """
        'use strict';
        export function update() { thisScene.getLayer('fade').alpha = 0.25; }
        """
        let instance = try WPELayerScriptInstance(script: script)
        let output = try #require(instance.tick())
        let fade = try #require(output.others["fade"])
        #expect(fade.alpha == 0.25)
        #expect(fade.alphaAssigned == true)
        #expect(fade.visibleAssigned == false)
    }

    @Test("Cursor-only visible script keeps its parsed visible:false seed (3212731906 hover text)")
    func visibleScriptSeedFalsePreservedWhenNeverAssigned() throws {
        // 3212731906's hover text: a visible-script that only defines cursor
        // handlers, never assigning thisLayer.visible in init/update. The parsed
        // `visible:false` seed must survive — the old default forced own.visible
        // true (and visibleAssigned true), rendering the hover text permanently.
        let script = """
        'use strict';
        export function cursorEnter() { thisLayer.visible = true; }
        export function cursorLeave() { thisLayer.visible = false; }
        """
        let instance = try WPELayerScriptInstance(script: script, initialVisible: false)
        #expect(instance.initialOutput.own.visibleAssigned == false)
        #expect(instance.initialOutput.own.visible == false)

        // cursorEnter explicitly assigns → drives visible true.
        let entered = try #require(instance.dispatchCursorEvent(
            .enter,
            pointerFrame: .neutral
        ))
        #expect(entered.own.visibleAssigned == true)
        #expect(entered.own.visible == true)

        // cursorLeave assigns false again → drives hidden.
        let left = try #require(instance.dispatchCursorEvent(
            .leave,
            pointerFrame: .neutral
        ))
        #expect(left.own.visibleAssigned == true)
        #expect(left.own.visible == false)
    }

    @Test("Visible script that assigns visible=true overrides a false seed")
    func visibleScriptExplicitAssignmentOverridesSeed() throws {
        // A script whose init() sets thisLayer.visible = true must SHOW the layer
        // even though the parsed seed was false — an explicit assignment wins.
        let script = """
        'use strict';
        export function init() { thisLayer.visible = true; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script, initialVisible: false)
        #expect(instance.initialOutput.own.visibleAssigned == true)
        #expect(instance.initialOutput.own.visible == true)
    }

    @Test("Visible script that never touches alpha keeps the parsed alpha seed")
    func visibleScriptAlphaSeedPreservedWhenNeverAssigned() throws {
        // Same clobber family as the visible seed: a layerState-mode script that
        // never assigns thisLayer.alpha used to report own.alpha=1 with
        // alphaAssigned=true, overwriting a parsed alpha≠1 on apply.
        let script = """
        'use strict';
        export function init() { thisLayer.visible = true; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script, initialAlpha: 0.35)
        #expect(instance.initialOutput.own.alphaAssigned == false)
        #expect(instance.initialOutput.own.alpha == 0.35)
        // The tick path preserves the seed too.
        let ticked = try #require(instance.tick())
        #expect(ticked.own.alphaAssigned == false)
        #expect(ticked.own.alpha == 0.35)
    }

    @Test("Visible script that assigns alpha overrides the parsed seed")
    func visibleScriptExplicitAlphaOverridesSeed() throws {
        let script = """
        'use strict';
        export function init() { thisLayer.alpha = 0.8; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script, initialAlpha: 0.35)
        #expect(instance.initialOutput.own.alphaAssigned == true)
        #expect(instance.initialOutput.own.alpha == 0.8)
    }

    @Test("Cursor-follow transform scripts route to a dedicated lane, not the shared pool")
    func cursorTransformScriptUsesDedicatedFastLane() throws {
        // 3212731906's icon card: a per-frame origin script reading
        // input.cursorWorldPosition. On the shared pool it competes with a scene's
        // dozen time/audio/n-body scripts and drops to ~1Hz. It must instead route
        // to the dedicated cursor lane. Explicitly injected governors (test/other
        // callers) are always honored so pool isolation is preserved.
        let cursorScript = """
        'use strict';
        export function update(value) {
            value.x = input.cursorWorldPosition.x;
            value.y = input.cursorWorldPosition.y;
            return value;
        }
        """
        // Default (production) pool + reads cursor → fast lane.
        let cursorInstance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: cursorScript,
            seed: .zero,
            canvasSize: SIMD2<Double>(100, 100)
        )
        #expect(cursorInstance.debugUsesPointerFastLane == true)

        // Default pool but no cursor read → stays on the shared pool.
        let timeInstance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: "export function update(value) { value.y += 1; return value; }",
            seed: .zero,
            canvasSize: SIMD2<Double>(100, 100)
        )
        #expect(timeInstance.debugUsesPointerFastLane == false)

        // Explicit governor (the test helper injects isolatedGovernor) is never
        // rerouted, even for a cursor script.
        let isolated = try WPEDynamicTransformScriptInstance(
            script: cursorScript,
            seed: .zero,
            canvasSize: SIMD2<Double>(100, 100)
        )
        #expect(isolated.debugUsesPointerFastLane == false)
    }

    @Test("applyUserProperties activates the time-of-day switch (3470764447 后处理层)")
    func applyUserPropertiesDrivesTimeOfDaySwitch() throws {
        // Mirrors 3470764447's 后处理层: its update() gates the day/night switch on
        // `timeVarying`, which WPE sets ONLY through applyUserProperties. Without
        // that call update() no-ops, so the switch never narrows. init() only
        // REFERENCES the five layers (getLayer, no assignment), so they must NOT be
        // driven — a read-only reference leaves each band at its real scene
        // visibility. Bands span the whole day so any real wall-clock hour resolves
        // to `morning`, keeping it deterministic without a clock injection.
        let script = """
        'use strict';
        var displayVideo = ["morning", "day", "dusk", "night", "mddn"];
        var electDisplay = false;
        var timeVarying = false;
        var morningtime = 4, daytime = 9, dusktime = 17, nighttime = 20;
        export function init() {
            displayVideo = displayVideo.map(video => thisScene.getLayer(video));
        }
        var playVideo = function(num) {
            displayVideo.forEach((video, i) => {
                if (i === num) { video.getVideoTexture().play(); video.visible = true; }
                else { video.getVideoTexture().pause(); video.visible = false; }
            });
        }
        export function update() {
            var hours = (new Date()).getHours();
            if (timeVarying) {
                if (hours >= morningtime && hours < daytime) playVideo(0);
                else if (hours >= daytime && hours < dusktime) playVideo(1);
                else if (hours >= dusktime && hours < nighttime) playVideo(2);
                else playVideo(3);
            }
        }
        export function applyUserProperties(p) {
            if (p.hasOwnProperty('timevarying')) timeVarying = p.timevarying;
            if (p.hasOwnProperty('morningtime')) morningtime = p.morningtime;
            if (p.hasOwnProperty('daytime')) daytime = p.daytime;
            if (p.hasOwnProperty('dusktime')) dusktime = p.dusktime;
            if (p.hasOwnProperty('nighttime')) nighttime = p.nighttime;
        }
        """
        let bands = ["morning", "day", "dusk", "night", "mddn"]
        let instance = try WPELayerScriptInstance(script: script)

        // init() only REFERENCES the five layers (getLayer, no visibility assignment),
        // so none is driven — each stays at its real scene visibility. update() also
        // no-ops while timeVarying is false, so the switch cannot narrow yet.
        #expect(bands.allSatisfy { instance.initialOutput.others[$0] == nil })
        let beforeProps = try #require(instance.tick())
        #expect(bands.allSatisfy { beforeProps.others[$0] == nil })

        // Fix: deliver the user-property bag (timevarying on, bands covering all
        // 24h → morning). The next tick narrows to exactly the morning layer.
        instance.applyUserProperties([
            "timevarying": .bool(true),
            "morningtime": .number(0),
            "daytime": .number(24),
            "dusktime": .number(24),
            "nighttime": .number(24),
        ])
        let afterProps = try #require(instance.tick())
        #expect(afterProps.others["morning"]?.visible == true)
        #expect(afterProps.others["morning"]?.videoCommands.contains(.play) == true)
        for hidden in ["day", "dusk", "night", "mddn"] {
            #expect(afterProps.others[hidden]?.visible == false)
            #expect(afterProps.others[hidden]?.videoCommands.contains(.pause) == true)
        }
    }

    @Test("applyUserProperties is a safe no-op for scripts without the handler")
    func applyUserPropertiesNoHandlerIsSafe() throws {
        let script = """
        'use strict';
        export function init() { thisLayer.visible = true; }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(script: script)
        // No applyUserProperties handler → returns the current state, unchanged.
        let output = try #require(instance.applyUserProperties(["timevarying": .bool(true)]))
        #expect(output.own.visible == true)
        #expect(try #require(instance.tick()).own.visible == true)
    }

    @Test("shared state coordinates across two layer scripts in one scene")
    func sharedStateCoordinatesAcrossInstances() throws {
        let store = WPESharedScriptState()
        // Writer runs init first (synchronously), seeding `shared`.
        _ = try WPELayerScriptInstance(script: """
        export function init() { shared.flag = true; shared.count = 7; }
        export function update() {}
        """, shared: store).initialOutput
        let reader = try WPELayerScriptInstance(script: """
        export function init() { thisLayer.visible = (shared.flag === true && shared.count === 7); }
        export function update() {}
        """, shared: store)
        #expect(reader.initialOutput.own.visible == true)
    }

    /// 三体 3509243656's 日志 (object 1227) keeps its whole civilisation state in
    /// `shared` CONTAINERS and mutates them in place: `logEntries.unshift(...)`,
    /// `civilizationRecords.push(...)`, `lastStates.<field> = ...`. Values cross the
    /// host bridge by copy, so without a write-back proxy every mutation hit a
    /// detached temporary — the log and the survival leaderboard stayed empty
    /// forever while the primitive counters ticked on.
    @Test("shared container mutations round-trip across scripts")
    func sharedContainerMutationsPersist() throws {
        let store = WPESharedScriptState()
        _ = try WPELayerScriptInstance(script: """
        export function init() {
            shared.logEntries = [];
            shared.records = [];
            shared.lastStates = { rocheLimit: '' };
        }
        export function update() {
            shared.logEntries.unshift('entry');
            shared.records.push({ number: 1, lifespan: 8 });
            shared.lastStates.rocheLimit = '大撕裂';
        }
        """, shared: store)
        .tick()
        // Read into locals and guard every deref: a regression leaves these
        // undefined, and an uncaught TypeError would abort init() BEFORE the
        // assignment — leaving `visible` at its default and passing spuriously.
        let reader = try WPELayerScriptInstance(script: """
        export function init() {
            const le = shared.logEntries, rc = shared.records, ls = shared.lastStates;
            thisLayer.visible = !!le && le.length === 1
                && !!rc && rc.length === 1 && rc[0].lifespan === 8
                && !!ls && ls.rocheLimit === '大撕裂';
        }
        export function update() {}
        """, shared: store)
        #expect(reader.initialOutput.own.visible == true)
    }

    /// `civilizationRecords.find(r => ...).lifespan = n` — 1227 live-updates the
    /// running civilisation's lifespan through an element handed out by `find()`,
    /// so the write-back must reach the ROOT container from any depth.
    @Test("shared element mutation via find() writes back to the store")
    func sharedNestedElementMutationPersists() throws {
        let store = WPESharedScriptState()
        _ = try WPELayerScriptInstance(script: """
        export function init() { shared.records = [{ number: 2, lifespan: 0 }]; }
        export function update() {
            const r = shared.records.find(x => x.number === 2);
            if (r) { r.lifespan = 99; }
        }
        """, shared: store)
        .tick()
        let reader = try WPELayerScriptInstance(script: """
        export function init() {
            const rc = shared.records;
            thisLayer.visible = !!rc && rc.length === 1 && rc[0].lifespan === 99;
        }
        export function update() {}
        """, shared: store)
        #expect(reader.initialOutput.own.visible == true)
    }

    @Test("applyUserProperties can seed shared state from scriptProperties")
    func applyUserPropertiesSeedsSharedState() throws {
        let store = WPESharedScriptState()
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'menuEn', value: true })
            .finish();
        export function applyUserProperties(changedUserProperties) {
            if (!scriptProperties.menuEn) { shared.dd = 0; }
            else { shared.dd = 1; }
        }
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            scriptProperties: ["menuEn": .bool(true)],
            shared: store
        )
        _ = instance.applyUserProperties(["menuinit": .bool(true)])
        #expect(store.get("dd") as? Double == 1)
    }

    @Test("getParent / getAnimationLayer / scene.on stubs let a UI script run without throwing")
    func hierarchyAndEventStubsDoNotThrow() throws {
        // If any stub threw, init() would degrade to the force-visible fallback
        // (own.visible == true). scale.x == 1 → the script sets visible = false,
        // which proves init ran clean through all three APIs.
        let instance = try WPELayerScriptInstance(script: """
        scene.on("update", function() {});
        let parent;
        export function init() {
            parent = thisLayer.getParent().getParent();
            thisLayer.getAnimationLayer("x").play();
            thisLayer.visible = Math.abs(parent.scale.x) < 0.05;
        }
        export function update() {}
        """, shared: WPESharedScriptState())
        #expect(instance.initialOutput.own.visible == false)
    }

    @Test("thisScene.createLayer returns a writable layer handle")
    func createLayerStubReturnsWritableLayerHandle() throws {
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            let point = thisScene.createLayer({
                origin: new Vec3(1, 2, 3),
                alpha: 0,
                visible: false
            });
            point.color = new Vec3(1, 0, 0);
            point.scale = new Vec3(0.1, 0.1, 0.1);
            point.alpha = 0.5;
            point.visible = true;
            shared.created = point.visible && point.alpha === 0.5 ? 1 : 0;
        }
        export function update() {}
        """, shared: store)

        #expect(instance.initialOutput.own.visible == true)
        #expect(instance.initialOutput.created.first?.imagePath == "")
        #expect(store.get("created") as? Double == 1)
    }

    @Test("thisScene.createLayer exposes created layer state")
    func createLayerExposesCreatedLayerState() throws {
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            let point = thisScene.createLayer({
                image: "models/ta.json",
                origin: new Vec3(1, 2, 3),
                color: new Vec3(0.25, 0.5, 0.75),
                alpha: 0.25,
                scale: new Vec3(0.1, 0.2, 0.3),
                visible: true
            });
            point.origin = new Vec3(4, 5, 6);
            point.alpha = 0.75;
        }
        export function update() {}
        """)

        let created = try #require(instance.initialOutput.created.first)
        #expect(created.imagePath == "models/ta.json")
        #expect(created.origin == SIMD3<Double>(4, 5, 6))
        #expect(created.color == SIMD3<Double>(0.25, 0.5, 0.75))
        #expect(created.scale == SIMD3<Double>(0.1, 0.2, 0.3))
        #expect(created.alpha == 0.75)
        #expect(created.visible == true)
    }

    @Test("Layer script receives cursor input and click handlers")
    func layerScriptReceivesCursorInputAndClickHandlers() throws {
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(
            script: """
            export function cursorDown() { shared.down = 1; }
            export function cursorUp() { shared.up = 1; }
            export function update() {
                shared.x = input.cursorScreenPosition.x;
                shared.y = input.cursorScreenPosition.y;
                thisLayer.alpha = shared.down === 1 && shared.up !== 1 ? 0.25 : 1;
            }
            """,
            shared: store,
            canvasSize: SIMD2<Double>(200, 100)
        )

        let downFrame = WPEPointerFrame(
            position: SIMD2<Double>(0.25, 0.75),
            clickPosition: SIMD2<Double>(0.25, 0.75),
            isDown: true,
            isRightDown: false
        )
        _ = instance.dispatchCursorEvent(.down, pointerFrame: downFrame)
        let downOutput = try #require(instance.tick(pointerFrame: downFrame))

        #expect(store.get("down") as? Double == 1)
        #expect(store.get("x") as? Double == 50)
        #expect(store.get("y") as? Double == 75)
        #expect(downOutput.own.alpha == 0.25)

        let upFrame = WPEPointerFrame(
            position: SIMD2<Double>(0.4, 0.2),
            clickPosition: SIMD2<Double>(0.25, 0.75),
            isDown: false,
            isRightDown: false
        )
        _ = instance.dispatchCursorEvent(.up, pointerFrame: upFrame)
        let upOutput = try #require(instance.tick(pointerFrame: upFrame))

        #expect(store.get("up") as? Double == 1)
        #expect(store.get("x") as? Double == 80)
        #expect(store.get("y") as? Double == 20)
        #expect(upOutput.own.alpha == 1)
    }

    // MARK: - Async latest-snapshot ticks (ADR-003 step 1)

    @Test("Outcome slot: newest wins, consume-once, in-flight back-pressure")
    func outcomeSlotSemantics() throws {
        let slot = WPESceneScriptOutcomeSlot<Int>()
        #expect(slot.takeLatest() == nil)
        slot.publishEvent(1)
        slot.publishEvent(2)
        // The newer publish supersedes the older one; the older can never win.
        #expect(slot.takeLatest() == 2)
        // Consumed → the keep-last sentinel until something new completes.
        #expect(slot.takeLatest() == nil)
        let firstClaim = try #require(slot.beginTick())
        // One tick in flight → natural back-pressure, no second claim.
        #expect(slot.beginTick() == nil)
        #expect(slot.publishTick(3, for: firstClaim))
        let rejectedClaim = try #require(slot.beginTick())
        #expect(slot.rejectTick(rejectedClaim))
        let freshClaim = try #require(slot.beginTick())
        #expect(!slot.publishTick(99, for: rejectedClaim))
        #expect(slot.publishTick(4, for: freshClaim))
        #expect(slot.takeLatest() == 4)
        // A bounded synchronous evaluation folds + consumes pending outcomes, so
        // an older pending tick can't resurface after the newer applied result.
        slot.publishEvent(5)
        #expect(slot.supersede(with: 6) == 6)
        #expect(slot.takeLatest() == nil)
    }

    @Test("Layer outputs merge: video commands accumulate, newest state wins")
    func layerOutputMergePreservesVideoCommands() {
        let pending = WPELayerScriptOutput(
            own: WPELayerScriptState(visible: false, alpha: 0.25, videoCommands: [.play]),
            others: [
                "loop": WPELayerScriptState(
                    visible: true, alpha: 1, videoCommands: [.seek(0)],
                    visibleAssigned: false, alphaAssigned: false
                ),
                "both": WPELayerScriptState(visible: false, alpha: 0, videoCommands: [.pause]),
            ]
        )
        let newer = WPELayerScriptOutput(
            own: WPELayerScriptState(visible: true, alpha: 1, videoCommands: [.stop]),
            others: ["both": WPELayerScriptState(visible: true, alpha: 0.5, videoCommands: [])]
        )
        let merged = LiveWallpaper.WPELayerScriptInstance.mergedOutputs(pending: pending, newer: newer)
        #expect(merged.own.visible == true)
        #expect(merged.own.videoCommands == [.play, .stop])
        #expect(merged.others["both"]?.visible == true)
        #expect(merged.others["both"]?.videoCommands == [.pause])
        // A command-only entry the newer run no longer reports is still carried.
        #expect(merged.others["loop"]?.videoCommands == [.seek(0)])
    }

    @Test("Async text tick fails closed without publishing a late result")
    func asyncTickFailsClosedOnSlowScript() async throws {
        let script = """
        var n = 0;
        export function update(value) {
            n += 1;
            if (n === 1) { return 'fast-1'; }
            if (n === 2) {
                var t0 = Date.now();
                while (Date.now() - t0 < 500) {}
                return 'slow-2';
            }
            return 'tick-' + n;
        }
        """
        // Budget 0.1s < the 0.5s busy loop. The frame call remains nonblocking,
        // then quarantines the engine and must never accept its late completion.
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "seed",
            tickBudget: 0.1
        )
        instance.seedAsyncTick()
        // Drains the seed outcome and schedules the slow tick 2.
        #expect(instance.liveTickString() == "fast-1")
        let clock = ContinuousClock()
        let start = clock.now
        let duringBusy = instance.liveTickString()
        let elapsed = clock.now - start
        #expect(elapsed < .milliseconds(50))
        // Keep-last sentinel while the tick is in flight.
        #expect(duringBusy == "fast-1")
        try await Task.sleep(nanoseconds: 150_000_000)
        let quarantineStart = clock.now
        #expect(instance.liveTickString() == "fast-1")
        #expect(clock.now - quarantineStart < .milliseconds(50))

        // Let the abandoned JS call finish; its completion token is no longer
        // valid, so it cannot overwrite the last stable value.
        try await Task.sleep(nanoseconds: 450_000_000)
        for _ in 0..<10 {
            #expect(instance.liveTickString() == "fast-1")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("Seeded text script serves the scripted value on the first live tick")
    func textSeedAvoidsPlaceholderPop() throws {
        let instance = try WPESceneScriptInstance(
            script: "export function update(value) { return 'scripted'; }",
            initialValue: "placeholder"
        )
        instance.seedAsyncTick()
        #expect(instance.liveTickString() == "scripted")
    }

    @Test("Kill-switch legacy path: synchronous tick returns the fresh result immediately")
    func legacySynchronousTickReturnsImmediately() throws {
        // With WPEScriptAsyncTickEnabled=false the renderer calls tickString()
        // directly — the result of THIS tick is available synchronously.
        let instance = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '!'; }",
            initialValue: "x"
        )
        #expect(instance.tickString() == "x!")
        #expect(instance.tickString() == "x!!")
    }

    @Test("Seeded transform script serves its scripted value on the first live tick")
    func transformSeedAvoidsFirstFramePop() throws {
        let script = """
        export function update(value) { value.x = value.x + 1; return value; }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )
        instance.seedAsyncTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
        let first = instance.liveTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
        #expect(first == SIMD3<Double>(11, 20, 30))
    }

    @Test("Async transform ticks chain lastValue like the legacy path")
    func asyncTransformChainsLastValue() async throws {
        let script = """
        export function update(value) { value.x = value.x + 1; return value; }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(10, 20, 30),
            canvasSize: SIMD2<Double>(100, 100)
        )
        instance.seedAsyncTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
        #expect(instance.liveTick(pointerPosition: SIMD2<Double>(0.5, 0.5)) == SIMD3<Double>(11, 20, 30))
        // The tick scheduled above fed on lastValue=11; while it is in flight the
        // previous result persists (never a pop back to the baked seed).
        var sawChainedResult = false
        for _ in 0..<200 {
            let value = instance.liveTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
            if value == SIMD3<Double>(12, 20, 30) {
                sawChainedResult = true
                break
            }
            #expect(value == SIMD3<Double>(11, 20, 30))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(sawChainedResult)
    }

    @Test("Async cursor event outcome drains through the next liveTick")
    func asyncCursorEventDrainsThroughLiveTick() async throws {
        let script = """
        export function cursorDown() {
            thisLayer.getVideoTexture().play();
            thisLayer.alpha = 0.25;
        }
        export function update() {}
        """
        let instance = try WPELayerScriptInstance(
            script: script,
            governor: WPESceneScriptExecutionGovernor(limit: 1)
        )
        let frame = WPEPointerFrame(
            position: SIMD2<Double>(0.5, 0.5),
            clickPosition: SIMD2<Double>(0.5, 0.5),
            isDown: true,
            isRightDown: false
        )
        instance.liveDispatchCursorEvent(.down, pointerFrame: frame)
        // The frame path is intentionally nonblocking. Poll subsequent frames
        // instead of treating the fail-fast synchronous tick as a queue fence.
        var received: WPELayerScriptOutput?
        for _ in 0..<100 {
            if let output = instance.liveTick(pointerFrame: frame) {
                received = output
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let output = try #require(received)
        #expect(output.own.videoCommands.contains(.play))
        #expect(output.own.alpha == 0.25)
    }

    @Test("Superseding property push folds a pending tick's video commands")
    func supersedingPropertyPushFoldsPendingTick() throws {
        let script = """
        var started = false;
        export function update() {
            if (!started) { started = true; thisLayer.getVideoTexture().play(); }
            thisLayer.visible = true;
        }
        """
        let instance = try WPELayerScriptInstance(script: script)
        // Nothing completed yet — schedules tick 1, which issues .play.
        #expect(instance.liveTick() == nil)
        // Enqueued behind tick 1 on the serial queue, so tick 1 has published by
        // the time this bounded call returns; the fold must carry its .play.
        let merged = try #require(instance.applyUserPropertiesSuperseding(["k": .bool(true)]))
        #expect(merged.own.videoCommands.contains(.play))
        #expect(merged.own.visible == true)
        // Everything consumed — the older tick can't resurface a frame later.
        #expect(instance.liveTick() == nil)
    }

    @Test("Superseding property push waits out an in-flight slow tick without poisoning")
    func supersedingPropertyPushWaitsOutInFlightSlowTick() throws {
        let script = """
        var n = 0;
        export function update() {
            n += 1;
            if (n === 1) {
                var t0 = Date.now();
                while (Date.now() - t0 < 700) {}
                thisLayer.getVideoTexture().play();
            }
            thisLayer.visible = true;
        }
        export function applyUserProperties(p) { thisLayer.alpha = 0.5; }
        """
        // 0.7s busy loop: past the 0.5s tick budget (queued behind it, a plain
        // bounded push would time out and poison — the async watchdog merely
        // warns for the same tick) yet 0.3s clear of the superseding path's 2×
        // (1.0s) window, so scheduler noise can't tip the wait over.
        let instance = try WPELayerScriptInstance(script: script, tickBudget: 0.5)
        // Nothing completed yet — schedules the slow tick 1.
        #expect(instance.liveTick() == nil)
        // Enqueued behind the busy tick on the serial queue: the push must wait
        // it out and still fold the tick's published .play command in.
        let merged = try #require(instance.applyUserPropertiesSuperseding(["k": .bool(true)]))
        #expect(merged.own.alpha == 0.5)
        #expect(merged.own.videoCommands.contains(.play))
        #expect(merged.own.visible == true)
        // Not poisoned: a follow-up push on the now-idle queue still runs.
        #expect(instance.applyUserPropertiesSuperseding(["k": .bool(false)]) != nil)
    }

    // MARK: - Consumer-before-producer recovery (3509243656 三体)

    @Test("Text script that throws on unset shared state recovers on a later tick")
    func textScriptRecoversOnceSharedStateArrives() throws {
        // 3509243656's tooltip scripts read `shared.xx1.toFixed(2)` — before the
        // MAIN sim's first update() they throw (undefined.toFixed). The engine
        // must keep the last value AND retry: once the producer writes the key,
        // the very next tick recovers. A permanently-frozen instance here is the
        // regression this test locks out.
        let shared = WPESharedScriptState()
        let script = """
        export function update(value) {
            return '[' + shared.xx1.toFixed(2) + ']';
        }
        """
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "placeholder",
            shared: shared
        )
        // Producer hasn't run: the tick throws inside JS, value stays put.
        #expect(instance.tickString() == "placeholder")
        // Producer (script-host layer script) writes the shared key cross-context…
        let producer = try WPELayerScriptInstance(
            script: "export function update() { shared.xx1 = 1.5; }",
            shared: shared
        )
        _ = producer.tick(runtimeSeconds: 0, pointerFrame: .neutral)
        // …and the consumer's next retry succeeds.
        #expect(instance.tickString() == "[1.50]")
    }

    @Test("Parser keeps a script-driven text object whose authored value is empty")
    func parserKeepsScriptedTextWithEmptyAuthoredValue() throws {
        // 3509243656's `time` object authors "" and computes the string in
        // update() — it is the scene's ONLY shared.xntime producer. Dropping it
        // for the empty placeholder froze every consumer text in the scene.
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [
                {
                    "id": 345,
                    "name": "time",
                    "text": {
                        "script": "export function update(value) { return '1 Years'; }",
                        "value": ""
                    },
                    "origin": "0 0 0"
                },
                {
                    "id": 346,
                    "name": "empty-static",
                    "text": {"value": ""},
                    "origin": "0 0 0"
                }
            ]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        // Scripted empty text survives with an empty initial value…
        let scripted = try #require(document.textObjects.first(where: { $0.id == "345" }))
        #expect(scripted.text.isEmpty)
        #expect(scripted.textScript?.isEmpty == false)
        // …while a scriptless empty text is still dropped.
        #expect(!document.textObjects.contains(where: { $0.id == "346" }))
    }
}
