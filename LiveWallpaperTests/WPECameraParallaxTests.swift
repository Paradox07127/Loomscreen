import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
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

    private func parsedImageDepth(_ raw: Any) throws -> SIMD2<Double> {
        let doc = try parse([
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100, "auto": true]],
            "objects": [[
                "id": "1", "name": "Solid", "type": "image",
                "image": "models/util/solidlayer.json", "visible": true,
                "parallaxDepth": raw
            ]]
        ])
        return try #require(doc.imageObjects.first).parallaxDepth
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

    @Test("Negative mouseinfluence inverts parallax instead of disabling it")
    func negativeMouseInfluenceInvertsParallax() {
        func smoothedTarget(influence: Double) -> SIMD2<Float> {
            var smoother = WPECameraParallaxSmoother()
            let settings = WPESceneCameraParallaxSettings(
                enabled: true, amount: 0.5, delay: 0, mouseInfluence: influence
            )
            return smoother.frame(
                settings: settings,
                pointerPosition: SIMD2<Double>(1, 1),
                time: 0
            ).smoothed
        }
        let positive = smoothedTarget(influence: 0.5)
        let negative = smoothedTarget(influence: -0.5)
        #expect(positive != SIMD2<Float>(0, 0), "sanity: positive influence parallaxes")
        #expect(negative != SIMD2<Float>(0, 0), "negative influence must NOT be treated as off")
        #expect(negative == -positive, "negative influence mirrors the shift")
    }

    // MARK: - pixelOffset

    @Test("pixelOffset is zero for depth 0")
    func pixelOffsetDepthZero() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.5, 0.5))
        #expect(frame.pixelOffset(depth: SIMD2<Double>(0, 0), sceneSize: CGSize(width: 2560, height: 1440)) == SIMD2<Float>(0, 0))
    }

    @Test("pixelOffset sign: X negated, Y kept; magnitude scales with depth × gain")
    func pixelOffsetSign() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.2, 0.2))
        let off = frame.pixelOffset(depth: SIMD2<Double>(1, 1), sceneSize: CGSize(width: 1000, height: 1000))
        #expect(abs(off.x - (-100)) < 1e-3)
        #expect(abs(off.y - 100) < 1e-3)
    }

    @Test("pixelOffset clamps to ±maxShiftFraction regardless of depth/offset")
    func pixelOffsetClamp() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.5, -0.5))
        let off = frame.pixelOffset(depth: SIMD2<Double>(10, 10), sceneSize: CGSize(width: 1000, height: 1000))
        #expect(abs(off.x - (-200)) < 1e-3)
        #expect(abs(off.y - (-200)) < 1e-3)
    }

    @Test("gain scales the shift; a custom gain overrides the default")
    func pixelOffsetGain() {
        let scene = CGSize(width: 1000, height: 1000)
        let base = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.1, 0.1))
        let strong = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.1, 0.1), gain: 1.0)
        let b = base.pixelOffset(depth: SIMD2<Double>(1, 1), sceneSize: scene)
        let s = strong.pixelOffset(depth: SIMD2<Double>(1, 1), sceneSize: scene)
        #expect(abs(s.x - 2 * b.x) < 1e-3)
    }

    @Test("clampedGain: absent/non-finite → default; 0 honored (off); negatives→0; capped")
    func clampedGainResolution() {
        let dflt = WPECameraParallaxFrame.defaultGain
        #expect(WPECameraParallaxFrame.clampedGain(nil) == dflt)
        #expect(WPECameraParallaxFrame.clampedGain(.nan) == dflt)
        #expect(WPECameraParallaxFrame.clampedGain(.infinity) == dflt)
        #expect(WPECameraParallaxFrame.clampedGain(0) == 0)
        #expect(WPECameraParallaxFrame.clampedGain(-3) == 0)
        #expect(WPECameraParallaxFrame.clampedGain(0.8) == 0.8)
        #expect(WPECameraParallaxFrame.clampedGain(1000) == WPECameraParallaxFrame.maxGain)
    }

    @Test("pixelOffset honors per-axis depth: '1 0' horizontal-only, '0 1' vertical-only")
    func pixelOffsetPerAxis() {
        let frame = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0.3, 0.3))
        let scene = CGSize(width: 1000, height: 1000)
        let horizontalOnly = frame.pixelOffset(depth: SIMD2<Double>(1, 0), sceneSize: scene)
        #expect(abs(horizontalOnly.x - (-150)) < 1e-3)
        #expect(horizontalOnly.y == 0)
        let verticalOnly = frame.pixelOffset(depth: SIMD2<Double>(0, 1), sceneSize: scene)
        #expect(verticalOnly.x == 0)
        #expect(abs(verticalOnly.y - 150) < 1e-3)
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
            _ = s.frame(settings: settings, pointerPosition: SIMD2<Double>(0.5, 0.5), time: 0)
            var t = 0.0
            while t < 1.0 { t += dt; _ = s.frame(settings: settings, pointerPosition: cursor, time: t) }
            return s.smoothed
        }
        let a = run(fps: 30)
        let b = run(fps: 144)
        #expect(abs(a.x - b.x) < 0.02)
        #expect(abs(a.y - b.y) < 0.02)
    }

    // MARK: - parallaxDepth parsing (the "viewpoint never moves" root cause)

    @Test("parallaxDepth parses WPE's per-axis vector string (not 0)")
    func parsesVectorStringDepth() throws {
        #expect(try parsedImageDepth("1.000 1.000") == SIMD2<Double>(1, 1))
        #expect(try parsedImageDepth("0.50000 0.50000") == SIMD2<Double>(0.5, 0.5))
        #expect(try parsedImageDepth("0.00000 0.00000") == SIMD2<Double>(0, 0))
    }

    @Test("parallaxDepth keeps per-axis values and accepts a dict-wrapped vector")
    func parsesPerAxisAndWrappedDepth() throws {
        #expect(try parsedImageDepth("1 0") == SIMD2<Double>(1, 0))
        #expect(try parsedImageDepth("0 1") == SIMD2<Double>(0, 1))
        #expect(try parsedImageDepth("-0.5 0.25") == SIMD2<Double>(-0.5, 0.25))
        #expect(try parsedImageDepth(["user": "p0", "value": "0.5 0.5"]) == SIMD2<Double>(0.5, 0.5))
    }

    @Test("parallaxDepth still accepts a bare scalar and defaults to 0 when absent")
    func parsesScalarAndAbsentDepth() throws {
        #expect(try parsedImageDepth(2.0) == SIMD2<Double>(2, 2))
        #expect(try parsedImageDepth("3") == SIMD2<Double>(3, 3))
        let doc = try parse(minimalScene(general: [
            "orthogonalprojection": ["width": 100, "height": 100, "auto": true]
        ]))
        #expect(try #require(doc.imageObjects.first).parallaxDepth == SIMD2<Double>(0, 0))
    }

    // MARK: - Depth inheritance

    private func layer(
        _ id: String,
        depth: SIMD2<Double>,
        parent: String? = nil,
        attachment: String? = nil
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: id, objectName: id, imagePath: "models/util/solidlayer.json",
            materialPath: nil, parentObjectID: parent, attachment: attachment,
            geometry: .identity, compositeA: "_a", compositeB: "_b",
            localFBOs: [], passes: [], parallaxDepth: depth
        )
    }

    @Test("Whole parented rig inherits the root's per-axis depth (3719111841 shape)")
    func parentedRigInheritsRootDepth() {
        let pinned = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("hairRoot", depth: SIMD2<Double>(0.41, -0.36)),
            layer("body", depth: SIMD2<Double>(0, 0), parent: "hairRoot"),
            layer("head", depth: SIMD2<Double>(0, 0), parent: "body", attachment: "头部"),
            layer("eye", depth: SIMD2<Double>(0, 0), parent: "head", attachment: "眼"),
            layer("bg", depth: SIMD2<Double>(-0.17, -0.17))
        ])
        let byID = Dictionary(uniqueKeysWithValues: pinned.map { ($0.objectID, $0.parallaxDepth) })
        #expect(byID["hairRoot"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["body"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["head"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["eye"] == SIMD2<Double>(0.41, -0.36))
        #expect(byID["bg"] == SIMD2<Double>(-0.17, -0.17))
    }

    @Test("Pinning overwrites an intermediate/child's own nonzero depth (rigid-unit policy)")
    func inheritanceOverwritesOwnDepth() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("root", depth: SIMD2<Double>(0.4, 0.4)),
            layer("mid", depth: SIMD2<Double>(0.9, 0.9), parent: "root"),
            layer("leaf", depth: SIMD2<Double>(0, 0), parent: "mid")
        ])
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.objectID, $0.parallaxDepth) })
        #expect(byID["root"] == SIMD2<Double>(0.4, 0.4))
        #expect(byID["mid"] == SIMD2<Double>(0.4, 0.4))
        #expect(byID["leaf"] == SIMD2<Double>(0.4, 0.4))
    }

    @Test("A depth-0 root pins its children to 0 (Clock/Day/Date stay put)")
    func zeroDepthRootKeepsChildrenStill() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("clock", depth: SIMD2<Double>(0, 0)),
            layer("day", depth: SIMD2<Double>(0, 0), parent: "clock"),
            layer("date", depth: SIMD2<Double>(0, 0), parent: "clock")
        ])
        #expect(out.allSatisfy { $0.parallaxDepth == SIMD2<Double>(0, 0) })
    }

    @Test("No parented layers → input returned unchanged")
    func noParentsNoOp() {
        let input = [layer("a", depth: SIMD2<Double>(1, 1)), layer("b", depth: SIMD2<Double>(0.5, 0.5))]
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents(input)
        #expect(out == input)
    }

    @Test("A parent missing from the graph stops the walk at the last resolvable node")
    func danglingParentStopsWalk() {
        let out = WPERenderGraphBuilder.propagatingParallaxDepthThroughParents([
            layer("child", depth: SIMD2<Double>(0, 0), parent: "ghost")
        ])
        #expect(out.first?.parallaxDepth == SIMD2<Double>(0, 0))
    }
}
