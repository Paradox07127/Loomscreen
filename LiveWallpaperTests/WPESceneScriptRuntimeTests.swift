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
        // Initial render uses the static `value`; the script is
        // captured for runtime tick.
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
        // Subsequent ticks see the evolved value.
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
        // init() set counter to 100; first update() increments to 101.
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
        // Real corpus shape for a clock scene's property declaration.
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
        // The chainable stub returns proxies, so `scriptProperties.sep`
        // is undefined → string concat → "undefinedOK". Crucially the
        // script doesn't crash.
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
}
