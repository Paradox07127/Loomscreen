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

    @Test("createScriptProperties chain doesn't crash")
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
        let result = instance.tickString()
        #expect(result.hasSuffix("OK"))
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
}
