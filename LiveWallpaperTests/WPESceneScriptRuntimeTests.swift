import Foundation
import Testing
@testable import LiveWallpaper

@MainActor
struct WPESceneScriptRuntimeTests {

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

    @Test("Runaway update() loop is contained: tick times out and freezes at lastValue")
    func runawayUpdateLoopIsContained() throws {
        let script = """
        export function update(value) {
            if (value === 'armed') { while (true) {} }
            return 'armed';
        }
        """
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "start",
            setupBudget: 2.0,
            tickBudget: 0.2
        )
        #expect(instance.tickString() == "armed")
        // Second tick enters the infinite loop — must return within budget
        // instead of hanging, then stay frozen (poisoned) without re-touching
        // the hung JSContext.
        #expect(instance.tickString() == "armed")
        #expect(instance.tickString() == "armed")
    }

    @Test("Runaway module body times out at setup instead of hanging load")
    func runawaySetupTimesOut() {
        #expect(throws: WPESceneScriptError.executionTimedOut) {
            _ = try WPESceneScriptInstance(
                script: "while (true) {}",
                initialValue: "init",
                setupBudget: 0.2,
                tickBudget: 0.2
            )
        }
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
            seed: .init(0, 0, 0)))
        #expect(abs(origin.x - 300) < 0.001)   // override wins over the const default 0.5
        #expect(abs(origin.y - 700) < 0.001)
    }

    @Test("Dynamic (audio/time/random) scripts are not statically resolved")
    func dynamicScriptsAreSkipped() {
        #expect(WPETransformScriptEvaluator.isStaticallyResolvable(Self.originScript))
        #expect(!WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = engine.getFrequency(0); return v; }"))
        #expect(!WPETransformScriptEvaluator.isStaticallyResolvable(
            "export function update(v){ v.x = Math.random(); return v; }"))
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 100, canvasHeight: 100)
        #expect(evaluator.resolveVec3(
            script: "export function update(v){ v.x = engine.getTimeOfDay(); return v; }",
            properties: [:], seed: .init(1, 2, 3)) == nil)
    }

    @Test("A runaway origin script times out and falls back to the baked value")
    func runawayOriginScriptTimesOut() {
        // No dynamic token, so it passes the static filter and actually runs;
        // the budget guard must stop it instead of hanging the parser.
        let evaluator = WPETransformScriptEvaluator(
            canvasWidth: 100, canvasHeight: 100, evaluationBudget: 0.1)
        let runaway = "export function update(v){ while (true) {} return v; }"
        #expect(evaluator.resolveVec3(script: runaway, properties: [:], seed: .init(5, 6, 7)) == nil)
        // Poisoned: even a well-behaved script now short-circuits to baked.
        #expect(evaluator.resolveVec3(
            script: Self.originScript,
            properties: ["x": .number(0.5), "y": .number(0.5)],
            seed: .init(1, 2, 3)) == nil)
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

    @Test("applyUserProperties activates the time-of-day switch (3470764447 后处理层)")
    func applyUserPropertiesDrivesTimeOfDaySwitch() throws {
        // Mirrors 3470764447's 后处理层: its update() gates the day/night switch on
        // `timeVarying`, which WPE sets ONLY through applyUserProperties. Without
        // that call, init()'s getLayer() leaves all five time-band layers at the
        // default visible=true and update() no-ops — the bug. Bands span the whole
        // day so any real wall-clock hour resolves to `morning`, keeping it
        // deterministic without a clock injection.
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

        // Bug repro: init referenced all five layers, so they all default-show, and
        // update() can't narrow because timeVarying is still false.
        #expect(bands.allSatisfy { instance.initialOutput.others[$0]?.visible == true })
        let beforeProps = try #require(instance.tick())
        #expect(bands.allSatisfy { beforeProps.others[$0]?.visible == true })

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
}
