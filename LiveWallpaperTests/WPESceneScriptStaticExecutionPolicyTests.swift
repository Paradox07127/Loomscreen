import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite(.serialized)
struct WPESceneScriptStaticExecutionPolicyTests {
    /// The XPC worker re-validates every batch independently of the client. If its
    /// gate drifts from the bake-time eligibility gate, the worker rejects items
    /// the client already accepted and the whole batch silently falls back to
    /// baked values. Pin the two lists together so a one-sided edit fails the build.
    @Test("Worker re-validation gate matches the bake-time eligibility gate")
    func gatesShareOneList() {
        #expect(
            SceneScriptStaticExecutionPolicy.dynamicTokens
                == WPETransformScriptStaticAnalysis.dynamicTokens
        )
        #expect(
            SceneScriptStaticExecutionPolicy.blocklistPatterns
                == WPETransformScriptStaticAnalysis.staticExecutionBlocklistPatterns
        )
    }

    @Test("Both gates classify representative scripts identically")
    func gatesAgreeOnScripts() {
        let scripts = [
            "export function update(t){ return { x: t.x * 2, y: t.y }; }",
            "function update(t){ return { x: engine.runtime.time, y: t.y }; }",
            "function update(t){ return { x: Math.random(), y: 0 }; }",
            "function update(t){ for (var i = 0; i < 10; i++) {} return t; }",
            "function update(t){ while (true) {} }",
            "function update(t){ return { x: shared.foo, y: 0 }; }",
            "function update(t){ return { x: t.x, y: t.y + 1 }; }"
        ]
        for script in scripts {
            #expect(
                SceneScriptStaticExecutionPolicy.isStaticallyResolvable(script)
                    == WPETransformScriptStaticAnalysis.isStaticallyResolvable(script),
                "gates disagree on: \(script)"
            )
        }
    }

    /// A real `.app` with no embedded helper is a tampered/incomplete bundle. It
    /// must keep baked origins, never re-run untrusted community JS in-process.
    @Test("Application host without helper fails closed instead of running JS in-process")
    func applicationHostFailsClosed() {
        #expect(
            WPETransformScriptEvaluator.executionRoute(
                embeddedServiceAvailable: false,
                hostIsApplicationBundle: true
            ) == .keepBakedFailClosed
        )
    }

    @Test("Helper availability always routes to the isolated worker")
    func helperAvailabilityRoutesToWorker() {
        #expect(
            WPETransformScriptEvaluator.executionRoute(
                embeddedServiceAvailable: true,
                hostIsApplicationBundle: true
            ) == .helperService
        )
        #expect(
            WPETransformScriptEvaluator.executionRoute(
                embeddedServiceAvailable: true,
                hostIsApplicationBundle: false
            ) == .helperService
        )
    }

    @Test("Only a non-app host may evaluate in-process")
    func nonApplicationHostMayRunInProcess() {
        #expect(
            WPETransformScriptEvaluator.executionRoute(
                embeddedServiceAvailable: false,
                hostIsApplicationBundle: false
            ) == .inProcess
        )
    }
}
