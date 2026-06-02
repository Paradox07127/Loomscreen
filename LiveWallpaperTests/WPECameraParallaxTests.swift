import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("WPE camera parallax")
struct WPECameraParallaxTests {

    private func parse(_ payload: [String: Any]) throws -> WPESceneDocument {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try WPESceneDocumentParser.parse(data: data)
    }

    private func minimalScene(general: [String: Any]) -> [String: Any] {
        [
            "camera": ["center": "0 0 0"],
            "general": general,
            "objects": [[
                "id": "1", "name": "Solid", "type": "image",
                "image": "models/util/solidlayer.json", "visible": true
            ]]
        ]
    }

    // MARK: - Parser

    @Test("Parses camera parallax settings")
    func parsesSettings() throws {
        let doc = try parse(minimalScene(general: [
            "orthogonalprojection": ["width": 2560, "height": 1440, "auto": true],
            "cameraparallax": true,
            "cameraparallaxamount": 0.8,
            "cameraparallaxdelay": 0.2,
            "cameraparallaxmouseinfluence": 0.4
        ]))
        let p = doc.general.cameraParallax
        #expect(p.enabled == true)
        #expect(abs(p.amount - 0.8) < 1e-9)
        #expect(abs(p.delay - 0.2) < 1e-9)
        #expect(abs(p.mouseInfluence - 0.4) < 1e-9)
    }

    @Test("Defaults to disabled with WPE default scalars when absent")
    func defaultsWhenAbsent() throws {
        let doc = try parse(minimalScene(general: [
            "orthogonalprojection": ["width": 2560, "height": 1440, "auto": true]
        ]))
        #expect(doc.general.cameraParallax == .disabled)
        #expect(doc.general.cameraParallax.enabled == false)
        #expect(abs(doc.general.cameraParallax.amount - 0.5) < 1e-9)
    }

    // MARK: - pixelOffset

    @Test("pixelOffset is zero for depth 0")
    func pixelOffsetDepthZero() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.5, 0.5))
        #expect(frame.pixelOffset(depth: 0, sceneSize: CGSize(width: 2560, height: 1440)) == SIMD2<Float>(0, 0))
    }

    @Test("pixelOffset sign: X negated, Y kept; magnitude scales with depth")
    func pixelOffsetSign() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.2, 0.2))
        let off = frame.pixelOffset(depth: 1.0, sceneSize: CGSize(width: 1000, height: 1000))
        // uv = clamp(0.2 * 1.0 * 0.1, ±0.05) = 0.02 → (-0.02*1000, 0.02*1000)
        #expect(abs(off.x - (-20)) < 1e-3)
        #expect(abs(off.y - 20) < 1e-3)
    }

    @Test("pixelOffset clamps to ±0.05 UV regardless of depth/offset")
    func pixelOffsetClamp() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.5, -0.5))
        let off = frame.pixelOffset(depth: 10.0, sceneSize: CGSize(width: 1000, height: 1000))
        // raw uv = 0.5 * 10 * 0.1 = 0.5 → clamps to 0.05 → (-50, ...)
        #expect(abs(off.x - (-50)) < 1e-3)
        #expect(abs(off.y - (-50)) < 1e-3)
    }

    // MARK: - Smoother

    @Test("Disabled / amount 0 / mouseInfluence 0 produce neutral")
    func smootherNoOp() {
        var s = WPECameraParallaxSmoother()
        let cursor = SIMD2<Double>(1, 1)
        #expect(s.frame(settings: .disabled, pointerPosition: cursor, time: 0) == .neutral)
        s.reset()
        #expect(s.frame(settings: .init(enabled: true, amount: 0, delay: 0.1, mouseInfluence: 0.5),
                        pointerPosition: cursor, time: 0) == .neutral)
        s.reset()
        #expect(s.frame(settings: .init(enabled: true, amount: 0.5, delay: 0.1, mouseInfluence: 0),
                        pointerPosition: cursor, time: 0) == .neutral)
    }

    @Test("First frame snaps to the calibrated cursor target")
    func smootherFirstFrameSnap() {
        var s = WPECameraParallaxSmoother()
        // WPE defaults → effectiveGlobal 1; cursor at right edge → target.x = 0.5
        let frame = s.frame(settings: .init(enabled: true, amount: 0.5, delay: 0.1, mouseInfluence: 0.5),
                            pointerPosition: SIMD2<Double>(1.0, 0.5), time: 0)
        #expect(abs(frame.smoothed.x - 0.5) < 1e-5)
        #expect(abs(frame.smoothed.y - 0.0) < 1e-5)
    }

    @Test("Smoothing converges to the same offset at 30 vs 144 FPS over equal elapsed time")
    func smootherFrameRateIndependent() {
        let settings = WPESceneCameraParallaxSettings(enabled: true, amount: 0.5, delay: 0.2, mouseInfluence: 0.5)
        let cursor = SIMD2<Double>(1.0, 0.5)
        func run(fps: Double) -> SIMD2<Float> {
            var s = WPECameraParallaxSmoother()
            let dt = 1.0 / fps
            // prime first frame at the center so the snap doesn't dominate
            _ = s.frame(settings: settings, pointerPosition: SIMD2<Double>(0.5, 0.5), time: 0)
            var t = 0.0
            // advance 1 second of cursor-at-edge
            while t < 1.0 { t += dt; _ = s.frame(settings: settings, pointerPosition: cursor, time: t) }
            return s.smoothed
        }
        let a = run(fps: 30)
        let b = run(fps: 144)
        #expect(abs(a.x - b.x) < 0.02)
        #expect(abs(a.y - b.y) < 0.02)
    }
}
